"use client";

import React, { useRef } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ArrowTopRightOnSquareIcon, Bars3Icon, BugAntIcon } from "@heroicons/react/24/outline";
import { NetworkPill } from "~~/components/orders/StatusBits";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-hbar";
import { useContractEntityId } from "~~/hooks/orders/useMarkets";
import { vault } from "~~/hooks/orders/useVault";
import { useOutsideClick } from "~~/hooks/scaffold-hbar";

type HeaderMenuLink = {
  label: string;
  href: string;
  icon?: React.ReactNode;
};

export const menuLinks: HeaderMenuLink[] = [
  {
    label: "Trade",
    href: "/",
  },
  {
    label: "My orders",
    href: "/orders",
  },
  {
    label: "Debug Contracts",
    href: "/debug",
    icon: <BugAntIcon className="h-4 w-4" />,
  },
];

const linkClass = "py-1.5 px-3 text-sm rounded-full gap-2 grid grid-flow-col";

export const HeaderMenuLinks = () => {
  const pathname = usePathname();
  const vaultId = useContractEntityId(vault.address);

  return (
    <>
      {menuLinks.map(({ label, href, icon }) => {
        const isActive = href === "/" ? pathname === "/" : pathname.startsWith(href);
        return (
          <li key={href}>
            <Link
              href={href}
              passHref
              className={`${isActive ? "bg-primary/10 text-primary font-semibold" : "hover:bg-primary/5"} ${linkClass}`}
            >
              {icon}
              <span>{label}</span>
            </Link>
          </li>
        );
      })}
      <li>
        {/* The scaffold's block explorer only reads local chains; on Hedera the vault's history lives on HashScan. */}
        <a
          href={`https://hashscan.io/testnet/contract/${vaultId ?? vault.address}`}
          target="_blank"
          rel="noreferrer"
          className={`hover:bg-primary/5 ${linkClass}`}
        >
          <span>Vault on HashScan</span>
          <ArrowTopRightOnSquareIcon className="h-4 w-4" />
        </a>
      </li>
    </>
  );
};

/**
 * Site header
 */
export const Header = () => {
  const burgerMenuRef = useRef<HTMLDetailsElement>(null);
  useOutsideClick(burgerMenuRef, () => {
    burgerMenuRef?.current?.removeAttribute("open");
  });

  return (
    <div className="sticky lg:static top-0 navbar bg-base-100 min-h-0 shrink-0 justify-between z-20 shadow-sm border-b border-base-300 px-0 sm:px-2">
      <div className="navbar-start w-auto lg:w-1/2">
        <details className="dropdown" ref={burgerMenuRef}>
          <summary
            className="ml-1 btn btn-ghost lg:hidden hover:bg-transparent"
            aria-label="Open navigation"
            data-testid="burger"
          >
            <Bars3Icon className="h-1/2" />
          </summary>
          <ul
            className="menu menu-compact dropdown-content mt-3 p-2 shadow-sm bg-base-100 rounded-box w-52"
            onClick={() => {
              burgerMenuRef?.current?.removeAttribute("open");
            }}
          >
            <HeaderMenuLinks />
          </ul>
        </details>
        <Link href="/" passHref className="flex items-center gap-2.5 ml-1 lg:ml-4 mr-4 shrink-0">
          <span
            className="grid h-8 w-8 place-items-center rounded-lg bg-primary text-sm font-bold text-primary-content"
            aria-hidden
          >
            L
          </span>
          <span className="hidden flex-col sm:flex">
            <span className="font-bold leading-tight text-base">Limit Orders</span>
            <span className="hidden text-[10px] font-medium tracking-wider text-base-content/60 uppercase sm:block">
              SaucerSwap V2 · Hedera
            </span>
          </span>
        </Link>
        <ul className="hidden lg:flex lg:flex-nowrap menu menu-horizontal px-1 gap-2">
          <HeaderMenuLinks />
        </ul>
      </div>
      <div className="navbar-end min-w-0 grow mr-2 gap-2 sm:mr-4">
        <NetworkPill />
        <RainbowKitCustomConnectButton />
      </div>
    </div>
  );
};
