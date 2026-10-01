import deployedContracts from "../../contracts/deployedContracts";
import { type Abi, type AbiEvent, encodeAbiParameters, encodeEventTopics, keccak256, toHex } from "viem";

/** Vault event logs built from the ABI, for receipts and for mirror-node fixtures written in code. */

const vaultAbi = deployedContracts[296].OrderVault.abi as Abi;
const VAULT = deployedContracts[296].OrderVault.address.toLowerCase();

/** An event name and its arguments by ABI input name. */
export type LogEvent = [eventName: string, args: Record<string, unknown>];

/** Topics and data of one vault event, as both the JSON-RPC receipt and the mirror node carry them. */
export const vaultLog = (eventName: string, args: Record<string, unknown>) => {
  const event = vaultAbi.find(i => i.type === "event" && i.name === eventName) as AbiEvent;
  const data = event.inputs.filter(i => !i.indexed);
  return {
    address: VAULT,
    topics: encodeEventTopics({ abi: [event], eventName, args } as never),
    data: encodeAbiParameters(
      data,
      data.map(i => args[i.name as string]),
    ),
  };
};

/**
 * One transaction's logs in the mirror node's shape (see `utils/orders/__fixtures__`): a shared consensus
 * timestamp ("seconds.nanos") and transaction hash, derived from `tag` so the fixture is stable.
 */
export const mirrorTx = (tag: string, seconds: number, events: LogEvent[]) => {
  const transaction_hash = keccak256(toHex(tag));
  const timestamp = `${seconds}.${String(BigInt(transaction_hash) % 1_000_000_000n).padStart(9, "0")}`;
  return events.map(([eventName, args]) => ({ ...vaultLog(eventName, args), timestamp, transaction_hash }));
};
