import React from "react";
import { HederaPortalFaucet } from "@scaffold-hbar-ui/components";
import { hedera } from "viem/chains";
import { CurrencyDollarIcon } from "@heroicons/react/24/outline";
import { SwitchTheme } from "~~/components/SwitchTheme";
import { useFetchHbarPrice } from "~~/hooks/scaffold-hbar";
import { useTargetNetwork } from "~~/hooks/scaffold-hbar/useTargetNetwork";

/**
 * Site footer
 */
export const Footer = () => {
  const { targetNetwork } = useTargetNetwork();
  const isTestnet = targetNetwork.id !== hedera.id;
  const { price: nativeCurrencyPrice } = useFetchHbarPrice();

  return (
    <footer className="grid min-h-0 gap-2 px-4 py-5">
      <div className="mx-auto flex w-full max-w-6xl flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap gap-2">
          {nativeCurrencyPrice > 0 && (
            <span className="btn btn-primary btn-sm cursor-auto gap-1 font-normal">
              <CurrencyDollarIcon className="h-4 w-4" />
              <span>{nativeCurrencyPrice.toFixed(2)}</span>
            </span>
          )}
          {isTestnet && <HederaPortalFaucet showIcon />}
        </div>
        <SwitchTheme />
      </div>
      <div className="w-full">
        <ul className="menu menu-horizontal w-full">
          <div className="flex justify-center items-center gap-3 text-sm w-full text-base-content/60">
            <a
              href="https://github.com/Jagadeeshftw/saucerswap-limit-orders"
              target="_blank"
              rel="noreferrer"
              className="link hover:text-primary"
            >
              Source
            </a>
            <span className="opacity-30">|</span>
            <span>
              Built on{" "}
              <a
                href="https://hedera.com/"
                target="_blank"
                rel="noreferrer"
                className="font-semibold link hover:text-primary"
              >
                Hedera
              </a>
            </span>
            <span className="opacity-30">|</span>
            <a href="https://docs.hedera.com/" target="_blank" rel="noreferrer" className="link hover:text-primary">
              Docs
            </a>
          </div>
        </ul>
      </div>
    </footer>
  );
};
