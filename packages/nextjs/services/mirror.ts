/**
 * Hedera mirror node REST client for what the chain's JSON-RPC cannot answer cheaply:
 * which order NFTs an account holds, token associations, an order's event history, and how far
 * the mirror node lags consensus.
 */

export const MIRROR_NODE_URL = process.env.NEXT_PUBLIC_MIRROR_NODE_URL || "https://testnet.mirrornode.hedera.com";

export class MirrorNodeError extends Error {
  constructor(
    readonly status: number,
    path: string,
  ) {
    super(`Mirror node returned ${status} for ${path}`);
  }
}

const get = async <T>(path: string): Promise<T> => {
  const res = await fetch(`${MIRROR_NODE_URL}${path}`, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new MirrorNodeError(res.status, path);
  return (await res.json()) as T;
};

export type MirrorAccount = {
  account: string;
  evm_address: string;
  max_automatic_token_associations: number;
  balance: { balance: number };
};

/** The account behind an EVM address, or null if it has never been used on this network. */
export const fetchAccount = async (evmAddress: string): Promise<MirrorAccount | null> => {
  try {
    return await get<MirrorAccount>(`/api/v1/accounts/${evmAddress}`);
  } catch (error) {
    if (error instanceof MirrorNodeError && error.status === 404) return null;
    throw error;
  }
};

/** Entity id of a contract from its EVM address, e.g. a CREATE2 pool that has no long-zero address. */
export const fetchContractId = async (evmAddress: string): Promise<string> =>
  (await get<{ contract_id: string }>(`/api/v1/contracts/${evmAddress}`)).contract_id;

type TokenRelationships = { tokens: { token_id: string; balance: number }[] };

/** Token ids the account is associated with, among `tokenIds`. */
export const fetchAssociations = async (accountId: string, tokenIds: string[]): Promise<Set<string>> => {
  const associated = new Set<string>();
  await Promise.all(
    tokenIds.map(async tokenId => {
      const body = await get<TokenRelationships>(`/api/v1/accounts/${accountId}/tokens?token.id=${tokenId}`);
      if (body.tokens.some(t => t.token_id === tokenId)) associated.add(tokenId);
    }),
  );
  return associated;
};

type NftPage = { nfts: { serial_number: number }[]; links: { next: string | null } };

/** Serial numbers (order ids) of a collection held by the account, following pagination. */
export const fetchHeldSerials = async (accountId: string, collectionId: string): Promise<bigint[]> => {
  const serials: bigint[] = [];
  let path: string | null = `/api/v1/accounts/${accountId}/nfts?token.id=${collectionId}&limit=100`;
  while (path) {
    const page: NftPage = await get<NftPage>(path);
    serials.push(...page.nfts.map(n => BigInt(n.serial_number)));
    path = page.links.next;
  }
  return serials;
};

export type MirrorLog = {
  address: string;
  data: `0x${string}`;
  topics: `0x${string}`[];
  timestamp: string;
  transaction_hash: string;
};

/** The mirror node only filters by topic within a timestamp range shorter than 7 days. */
const TOPIC_WINDOW_SECONDS = 7 * 24 * 60 * 60 - 60;

type TopicFilter = { topic0?: `0x${string}`; topic1?: `0x${string}`; topic3?: `0x${string}` };

/**
 * Every log of the contract at `contract` (entity id or EVM address) between `fromSeconds` and `toSeconds`
 * matching the topic filters, oldest first, walking the range in windows the mirror node accepts.
 */
export const fetchLogs = async (
  contract: string,
  topics: TopicFilter,
  fromSeconds: number,
  toSeconds: number,
): Promise<MirrorLog[]> => {
  const filter = Object.entries(topics)
    .map(([key, value]) => `&${key}=${value}`)
    .join("");
  const logs: MirrorLog[] = [];
  for (let start = fromSeconds; start <= toSeconds; start += TOPIC_WINDOW_SECONDS + 1) {
    const end = Math.min(start + TOPIC_WINDOW_SECONDS, toSeconds);
    let path: string | null =
      `/api/v1/contracts/${contract}/results/logs?order=asc&limit=100${filter}` +
      `&timestamp=gte:${start}&timestamp=lte:${end}`;
    while (path) {
      const page: { logs: MirrorLog[]; links: { next: string | null } } = await get(path);
      logs.push(...page.logs);
      path = page.links.next;
    }
  }
  return logs;
};

/** Seconds between now and the newest record the mirror node has ingested. */
export const fetchMirrorLagSeconds = async (): Promise<number> => {
  const body = await get<{ blocks: { timestamp: { to: string } }[] }>("/api/v1/blocks?limit=1&order=desc");
  const newest = Number(body.blocks[0]?.timestamp.to.split(".")[0] ?? 0);
  return Math.max(0, Math.round(Date.now() / 1000 - newest));
};
