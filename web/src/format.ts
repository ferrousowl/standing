import { BaseError, ContractFunctionRevertedError, formatUnits, type Address } from "viem";
import { tokenOf } from "./chain";

/** Escape text for interpolation into HTML. Plan names are user-controlled on-chain strings. */
export const esc = (s: unknown) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

export const short = (a: Address) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** Token amounts use 6 decimals through the ERC-20 interface. Trims to cents unless smaller. */
export function money(amount: bigint, token: Address, maxFrac = 2): string {
  const t = tokenOf(token);
  const n = Number(formatUnits(amount, 6));
  const frac = n !== 0 && Math.abs(n) < 0.01 ? 6 : maxFrac;
  const body = n.toLocaleString("en-US", { minimumFractionDigits: Math.min(2, frac), maximumFractionDigits: frac });
  return t.sign ? `${t.sign}${body}` : `${body} ${t.symbol}`;
}

const UNITS: [number, string][] = [
  [365 * 86400, "year"],
  [30 * 86400, "month"],
  [7 * 86400, "week"],
  [86400, "day"],
  [3600, "hour"],
];

/** "month", "2 weeks", "36 hours" */
export function period(seconds: number): string {
  for (const [size, name] of UNITS) {
    if (seconds % size === 0) {
      const n = seconds / size;
      return n === 1 ? name : `${n} ${name}s`;
    }
  }
  return `${Math.round(seconds / 3600)} hours`;
}

export function date(unix: number): string {
  return new Date(unix * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

/** "in 3 days", "2 hours ago". `now` is chain time, which is what decides whether a payment is due. */
export function relative(unix: number, now: number): string {
  const diff = unix - now;
  const abs = Math.abs(diff);
  const [size, name] = [...UNITS, [60, "minute"] as [number, string]].find(([s]) => abs >= s) ?? [1, "second"];
  const n = Math.max(1, Math.round(abs / size));
  const text = `${n} ${name}${n === 1 ? "" : "s"}`;
  return diff >= 0 ? `in ${text}` : `${text} ago`;
}

const REVERTS: Record<string, string> = {
  PullFailed: "The payment could not be collected. Check the USDC balance and the spending allowance.",
  AlreadySubscribed: "This wallet already has a live subscription to this plan.",
  PlanInactive: "This plan has been closed by its merchant.",
  OrderInactive: "This subscription is no longer active.",
  NotDue: "This payment is not due yet.",
  BadParams: "Those plan terms aren't valid. The executor cap can be at most half the price, and the tip at most the cap.",
  TokenNotAllowed: "That token isn't supported.",
  NotAuthorized: "This wallet isn't allowed to do that.",
};

/** Turn a viem error into one sentence a person can act on. */
export function explain(err: unknown): string {
  if (err instanceof BaseError) {
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName;
      if (name && REVERTS[name]) return REVERTS[name];
    }
    if (/user rejected|denied/i.test(err.shortMessage)) return "Cancelled in the wallet.";
    if (/insufficient funds/i.test(err.message)) return "Not enough USDC to cover this transaction and its fee.";
    return err.shortMessage;
  }
  return err instanceof Error ? err.message : String(err);
}
