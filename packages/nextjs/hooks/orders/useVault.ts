import { hederaTestnet } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";

/**
 * The OrderVault this app talks to: the one in deployedContracts.ts for Hedera testnet.
 * The mirror node accepts its EVM address directly; `useContractEntityId` gives the 0.0.x id for display.
 */
export const vault = {
  chainId: hederaTestnet.id,
  address: deployedContracts[hederaTestnet.id].OrderVault.address,
  abi: deployedContracts[hederaTestnet.id].OrderVault.abi,
} as const;

/** Polling cadence for on-chain reads; sweeps run every few minutes, so this is plenty fresh. */
export const REFRESH_MS = 15_000;
