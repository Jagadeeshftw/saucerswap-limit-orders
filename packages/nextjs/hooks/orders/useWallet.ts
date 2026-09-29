import { useQuery } from "@tanstack/react-query";
import { erc20Abi } from "viem";
import { useAccount, useBalance, useReadContracts } from "wagmi";
import { REFRESH_MS, vault } from "~~/hooks/orders/useVault";
import { fetchAccount, fetchAssociations } from "~~/services/mirror";
import { weibarToTinybar } from "~~/utils/orders/units";

/**
 * The connected wallet as the order screens need it: network, Hedera account, HBAR balance in tinybar,
 * and for each token its balance, allowance to the vault, and whether it can be received.
 */
export const useWallet = (tokens: { address: string; entityId: string }[], nftCollectionId: string | undefined) => {
  const { address, chainId, isConnected } = useAccount();
  const wrongNetwork = isConnected && chainId !== vault.chainId;

  const { data: hbar } = useBalance({
    address,
    chainId: vault.chainId,
    query: { enabled: Boolean(address), refetchInterval: REFRESH_MS },
  });

  const account = useQuery({
    queryKey: ["mirror-account", address],
    queryFn: () => fetchAccount(address as string),
    enabled: Boolean(address),
  });

  const watched = [...tokens.map(t => t.entityId), ...(nftCollectionId ? [nftCollectionId] : [])];
  const associations = useQuery({
    queryKey: ["associations", account.data?.account, watched.join(",")],
    queryFn: () => fetchAssociations(account.data!.account, watched),
    enabled: Boolean(account.data) && watched.length > 0,
    refetchInterval: REFRESH_MS,
  });

  const { data: tokenReads } = useReadContracts({
    contracts: tokens.flatMap(t => [
      {
        address: t.address as `0x${string}`,
        abi: erc20Abi,
        functionName: "balanceOf" as const,
        args: [address as `0x${string}`] as const,
        chainId: vault.chainId,
      },
      {
        address: t.address as `0x${string}`,
        abi: erc20Abi,
        functionName: "allowance" as const,
        args: [address as `0x${string}`, vault.address as `0x${string}`] as const,
        chainId: vault.chainId,
      },
    ]),
    query: { enabled: Boolean(address) && tokens.length > 0, refetchInterval: REFRESH_MS },
  });

  /** Unlimited automatic associations (-1) mean any HTS token can be received without a prior step. */
  const autoAssociates = account.data?.max_automatic_token_associations === -1;
  const canReceive = (entityId: string) => autoAssociates || Boolean(associations.data?.has(entityId));

  const token = (tokenAddress: string) => {
    const index = tokens.findIndex(t => t.address === tokenAddress);
    const balance = tokenReads?.[index * 2];
    const allowance = tokenReads?.[index * 2 + 1];
    return {
      balance: balance?.status === "success" ? (balance.result as bigint) : undefined,
      allowance: allowance?.status === "success" ? (allowance.result as bigint) : undefined,
    };
  };

  return {
    address,
    isConnected,
    wrongNetwork,
    accountId: account.data?.account,
    accountMissing: account.isSuccess && account.data === null,
    hbarTinybar: hbar ? weibarToTinybar(hbar.value) : undefined,
    canReceive,
    associationsReady: autoAssociates || associations.isSuccess,
    token,
  };
};
