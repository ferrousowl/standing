import { encodeFunctionData, parseUnits, toHex, type Address } from "viem";
import {
  DEPLOYED,
  MULTICALL3_FROM,
  STANDING,
  TOKENS,
  arc,
  client,
  erc20Abi,
  getOrders,
  getPlans,
  multicallFromAbi,
  range,
  standingAbi,
  tokenOf,
} from "./chain";
import { date, esc, explain, money, period, relative, short } from "./format";
import { connect, disconnect, onWallet, restore, send, state } from "./wallet";
import "./style.css";

const app = document.querySelector<HTMLElement>("#app")!;
const standing = { address: STANDING, abi: standingAbi } as const;
const explorer = arc.blockExplorers.default.url;

/** Gas an `execute` costs on Arc, measured on a mainnet fork. Used only for reward estimates. */
const EXECUTE_GAS = 130_000n;

/** Chain time in seconds. Due dates are judged by the chain's clock, not the visitor's. */
const chainNow = async () => Number((await client.getBlock()).timestamp);

// ───────────────────────────── shell ─────────────────────────────

function toast(message: string, kind: "ok" | "err" = "ok") {
  document.querySelector(".toast")?.remove();
  const el = document.createElement("div");
  el.className = `toast ${kind}`;
  el.setAttribute("role", "status");
  el.textContent = message;
  document.body.append(el);
  setTimeout(() => el.remove(), 6000);
}

/** Run a wallet action from a button: disable it, show progress, surface failures as a toast. */
async function act(button: HTMLButtonElement, busyLabel: string, fn: () => Promise<void>) {
  const label = button.textContent;
  button.disabled = true;
  button.textContent = busyLabel;
  try {
    await fn();
  } catch (err) {
    toast(explain(err), "err");
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
}

function header(): string {
  const account = state.address
    ? `<button class="chip" data-action="disconnect" title="Disconnect">${short(state.address)}</button>`
    : `<button class="btn small" data-action="connect">Connect wallet</button>`;
  const link = (href: string, text: string) =>
    `<a href="${href}" class="${location.hash === href || (href === "#/" && !location.hash) ? "on" : ""}">${text}</a>`;
  return `
    <header class="top">
      <a class="brand" href="#/"><span class="mark" aria-hidden="true"></span>Standing</a>
      <nav>${link("#/new", "Create a plan")}${link("#/account", "My account")}${link("#/keeper", "Keepers")}${link("#/integrate", "Integrate")}</nav>
      ${account}
    </header>`;
}

const footer = () => `
  <footer>
    <span>Standing orders on <a href="https://www.arc.io" target="_blank" rel="noopener">Arc</a> · non-custodial · open source (MIT)</span>
    ${DEPLOYED ? `<a href="${explorer}/address/${STANDING}" target="_blank" rel="noopener">Contract ${short(STANDING)}</a>` : ""}
  </footer>`;

// ───────────────────────────── views ─────────────────────────────

async function home(): Promise<string> {
  let stats = "";
  if (DEPLOYED) {
    const [plans, orders] = await Promise.all([
      client.readContract({ ...standing, functionName: "planCount" }),
      client.readContract({ ...standing, functionName: "orderCount" }),
    ]);
    const all = await getOrders(range(orders));
    const payments = all.reduce((n, o) => n + o.payments, 0);
    stats = `
      <dl class="stats">
        <div><dt>Plans</dt><dd>${plans}</dd></div>
        <div><dt>Subscriptions</dt><dd>${orders}</dd></div>
        <div><dt>Payments settled</dt><dd>${payments}</dd></div>
      </dl>`;
  }
  return `
    <section class="hero">
      <p class="eyebrow">Recurring payments for Arc</p>
      <h1>Get paid on schedule, in USDC, without running a billing server.</h1>
      <p class="lede">Publish a plan and share the link. Subscribers approve once. After that, anyone can
      settle a payment when it falls due — and is refunded the gas, in the same USDC the payment is made in.</p>
      <div class="row">
        <a class="btn" href="#/new">Create a plan</a>
        <a class="btn ghost" href="#/keeper">Earn by settling payments</a>
      </div>
      ${stats}
    </section>

    <section class="grid3">
      <article>
        <h3>One signature to subscribe</h3>
        <p>Approval and first payment go through in a single transaction, using Arc's sender-preserving
        batch contract. No second popup, no "approve, then come back".</p>
      </article>
      <article>
        <h3>Nobody has to press the button</h3>
        <p>Due payments are open for anyone to execute. The executor's gas is refunded out of the payment
        at the block's base fee, plus a small tip the merchant sets. Merchants cap the total.</p>
      </article>
      <article>
        <h3>Subscribers stay in control</h3>
        <p>Funds never leave the subscriber's wallet until a payment is due. Terms can't change after
        publishing, missed periods never stack up, and cancelling is one click.</p>
      </article>
    </section>

    <section class="why">
      <h2>Why this only works cleanly on Arc</h2>
      <p>On other chains a keeper spends ETH to move someone's USDC, so paying it back fairly needs a price
      oracle or a separate keeper token. On Arc gas <em>is</em> USDC: <code>gasUsed × basefee</code> is already a
      dollar amount. The contract converts it from 18 decimals to the 6 of the ERC-20 interface and pays
      it out of the payment it just collected. No oracle, no token, no trust.</p>
    </section>`;
}

function createPlan(): string {
  return `
    <section class="narrow">
      <h1>Create a plan</h1>
      <p class="muted">Terms are fixed once published, so subscribers know exactly what they agree to.</p>
      <form id="plan-form" class="card">
        <label>Plan name
          <input name="name" required maxlength="64" placeholder="Pro membership" autocomplete="off">
        </label>
        <div class="split">
          <label>Price
            <input name="amount" required inputmode="decimal" pattern="[0-9]*[.]?[0-9]{0,6}" placeholder="10.00">
          </label>
          <label>Currency
            <select name="token">${TOKENS.map((t) => `<option value="${t.address}">${t.symbol}</option>`).join("")}</select>
          </label>
        </div>
        <label>Billed every
          <select name="period">
            <option value="604800">week</option>
            <option value="2592000" selected>month (30 days)</option>
            <option value="31536000">year</option>
            <option value="86400">day</option>
            <option value="3600">hour (for testing)</option>
          </select>
        </label>
        <details>
          <summary>Executor settings</summary>
          <p class="muted small">Whoever settles a due payment is paid from it. You set the tip and the most
          you'll ever pay per payment. On USDC plans the gas refund (about $0.003) is added to the tip.</p>
          <div class="split">
            <label>Tip per payment
              <input name="tip" inputmode="decimal" value="0.002">
            </label>
            <label>Maximum per payment
              <input name="cap" inputmode="decimal" value="0.05">
            </label>
          </div>
        </details>
        <button class="btn" type="submit">${state.address ? "Publish plan" : "Connect wallet to publish"}</button>
      </form>
    </section>`;
}

async function planPage(id: bigint): Promise<string> {
  const count = await client.readContract({ ...standing, functionName: "planCount" });
  if (id >= count) return notFound("That plan doesn't exist.");
  const [plan] = await getPlans([id]);
  const token = tokenOf(plan.token);
  const subscribers = await client.readContract({ ...standing, functionName: "ordersOfPlan", args: [id] });

  let panel: string;
  if (!plan.active) {
    panel = `<p class="notice">This plan has been closed and takes no new subscribers.</p>`;
  } else if (!state.address) {
    panel = `<button class="btn wide" data-action="connect">Connect wallet to subscribe</button>`;
  } else {
    const [[live, orderId], paidUntil, balance, now] = await Promise.all([
      client.readContract({ ...standing, functionName: "liveOrderOf", args: [id, state.address] }),
      client.readContract({ ...standing, functionName: "paidUntil", args: [id, state.address] }),
      client.readContract({ address: plan.token, abi: erc20Abi, functionName: "balanceOf", args: [state.address] }),
      chainNow(),
    ]);
    if (live) {
      const [order] = await getOrders([orderId]);
      panel = `
        <p class="notice ok">You're subscribed. Next payment ${relative(order.nextDue, now)} (${date(order.nextDue)}).</p>
        <button class="btn ghost wide" data-action="cancel" data-id="${orderId}">Cancel subscription</button>`;
    } else {
      // Time already paid for survives a cancellation: coming back costs nothing until it runs out.
      const prepaid = paidUntil > now;
      const low = !prepaid && balance < plan.amount;
      panel = `
        ${prepaid ? `<p class="notice ok">You've already paid through ${date(paidUntil)}. Resubscribing is free until then.</p>` : ""}
        <label>Authorize payments for
          <select id="periods">
            <option value="3">3 payments</option>
            <option value="12" selected>12 payments</option>
            <option value="36">36 payments</option>
          </select>
        </label>
        <p class="muted small">${prepaid ? "Nothing is charged now." : `You pay ${money(plan.amount, plan.token)} now.`} Later payments are taken
        when due, up to the number you authorize. You can cancel or revoke at any time, and time you've paid for stays yours.</p>
        ${low ? `<p class="notice warn">This wallet holds ${money(balance, plan.token)} — not enough for the first payment.</p>` : ""}
        <button class="btn wide" data-action="subscribe" data-id="${id}" ${low ? "disabled" : ""}>${prepaid ? "Resubscribe" : "Subscribe"} · ${money(plan.amount, plan.token)} / ${period(plan.period)}</button>`;
    }
  }

  const isMerchant = state.address?.toLowerCase() === plan.merchant.toLowerCase();
  return `
    <section class="narrow">
      <div class="card plan">
        <p class="eyebrow">Subscription</p>
        <h1>${esc(plan.name)}</h1>
        <p class="price"><strong>${money(plan.amount, plan.token)}</strong> ${token.symbol} every ${period(plan.period)}</p>
        <dl class="facts">
          <div><dt>Paid to</dt><dd><a href="${explorer}/address/${plan.merchant}" target="_blank" rel="noopener">${short(plan.merchant)}</a></dd></div>
          <div><dt>Subscribers</dt><dd>${subscribers.length}</dd></div>
          <div><dt>Price changes</dt><dd>Not possible</dd></div>
        </dl>
        ${panel}
      </div>
      <div class="share">
        <span class="muted small">Share this plan</span>
        <button class="chip" data-action="copy" data-text="${esc(location.href)}">Copy link</button>
        ${isMerchant && plan.active ? `<button class="chip danger" data-action="close" data-id="${id}">Close plan</button>` : ""}
      </div>
    </section>`;
}

async function account(): Promise<string> {
  if (!state.address) {
    return `<section class="narrow center"><h1>My account</h1><p class="muted">Connect a wallet to see your
      subscriptions and the plans you've published.</p><button class="btn" data-action="connect">Connect wallet</button></section>`;
  }
  const me = state.address;
  const [orderIds, planIds, now] = await Promise.all([
    client.readContract({ ...standing, functionName: "ordersOf", args: [me] }),
    client.readContract({ ...standing, functionName: "plansOf", args: [me] }),
    chainNow(),
  ]);
  const orders = await getOrders([...orderIds]);
  const myPlans = await getPlans([...planIds]);
  const subscribedPlans = new Map((await getPlans([...new Set(orders.map((o) => o.planId))])).map((p) => [p.id, p]));

  const allowances = new Map<Address, bigint>();
  await Promise.all(
    [...new Set([...subscribedPlans.values()].map((p) => p.token))].map(async (token) => {
      const a = await client.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [me, STANDING] });
      allowances.set(token, a);
    }),
  );

  const subRows = orders
    .slice()
    .reverse()
    .map((o) => {
      const p = subscribedPlans.get(o.planId)!;
      const live = o.active && p.active;
      const left = (allowances.get(p.token) ?? 0n) / p.amount;
      const status = !live
        ? `<span class="tag">Ended</span>`
        : o.nextDue <= now
          ? `<span class="tag warn">Payment due</span>`
          : `<span class="tag ok">Active</span>`;
      return `
        <tr>
          <td><a href="#/plan/${p.id}">${esc(p.name)}</a></td>
          <td>${money(p.amount, p.token)} / ${period(p.period)}</td>
          <td>${status}</td>
          <td>${live ? `${relative(o.nextDue, now)}<br><span class="muted small">${left > 0n ? `${left} more authorized` : "authorization used up"}</span>` : "—"}</td>
          <td>${o.payments}</td>
          <td>${live ? `<button class="chip" data-action="cancel" data-id="${o.id}">Cancel</button>` : ""}</td>
        </tr>`;
    })
    .join("");

  const subscriberCounts = await Promise.all(
    myPlans.map((p) => client.readContract({ ...standing, functionName: "ordersOfPlan", args: [p.id] })),
  );
  const planRows = await Promise.all(
    myPlans
      .slice()
      .reverse()
      .map(async (p) => {
        const ids = subscriberCounts[myPlans.indexOf(p)];
        const subs = await getOrders([...ids]);
        const active = subs.filter((o) => o.active).length;
        const payments = subs.reduce((n, o) => n + o.payments, 0);
        return `
          <tr>
            <td><a href="#/plan/${p.id}">${esc(p.name)}</a></td>
            <td>${money(p.amount, p.token)} / ${period(p.period)}</td>
            <td>${p.active ? `<span class="tag ok">Open</span>` : `<span class="tag">Closed</span>`}</td>
            <td>${active}</td>
            <td>${payments}</td>
            <td>${money(p.amount * BigInt(payments), p.token)}</td>
          </tr>`;
      }),
  );

  const table = (head: string[], rows: string, empty: string) =>
    rows
      ? `<div class="scroll"><table><thead><tr>${head.map((h) => `<th>${h}</th>`).join("")}</tr></thead><tbody>${rows}</tbody></table></div>`
      : `<p class="empty">${empty}</p>`;

  return `
    <section>
      <h1>My account</h1>
      <h2>Subscriptions</h2>
      ${table(["Plan", "Price", "Status", "Next payment", "Paid", ""], subRows, "You haven't subscribed to anything yet.")}
      <h2>Plans I've published</h2>
      ${table(["Plan", "Price", "Status", "Active subscribers", "Payments", "Gross collected"], planRows.join(""), `Nothing published yet. <a href="#/new">Create a plan</a>.`)}
    </section>`;
}

async function keeper(): Promise<string> {
  const [total, now] = await Promise.all([client.readContract({ ...standing, functionName: "orderCount" }), chainNow()]);
  const ids = await client.readContract({ ...standing, functionName: "executable", args: [0n, total, 1n] });
  const orders = await getOrders([...ids]);
  const plans = new Map((await getPlans([...new Set(orders.map((o) => o.planId))])).map((p) => [p.id, p]));
  const fees = await Promise.all(
    orders.map((o) => client.readContract({ ...standing, functionName: "quoteExecFee", args: [o.planId, EXECUTE_GAS] })),
  );

  const rows = orders
    .map((o, i) => {
      const p = plans.get(o.planId)!;
      return `
        <tr>
          <td>#${o.id}</td>
          <td>${esc(p.name)}</td>
          <td>${money(p.amount, p.token)}</td>
          <td>${relative(o.nextDue, now)}</td>
          <td>${money(fees[i], p.token, 4)}</td>
        </tr>`;
    })
    .join("");

  const body = orders.length
    ? `<div class="scroll"><table><thead><tr><th>Order</th><th>Plan</th><th>Payment</th><th>Due</th><th>You receive</th></tr></thead><tbody>${rows}</tbody></table></div>
       <button class="btn" data-action="execute" data-ids="${ids.join(",")}">${state.address ? `Settle ${orders.length} payment${orders.length === 1 ? "" : "s"}` : "Connect wallet to settle"}</button>`
    : `<p class="empty">Nothing is due right now. ${total} subscription${total === 1n ? "" : "s"} on the books.</p>`;

  return `
    <section>
      <h1>Keepers</h1>
      <p class="lede">Payments below are due and collectable. Settle them and the contract pays you back your gas
      plus the merchant's tip, in the same transaction. No stake, no registration.</p>
      ${body}
      <h2>Run it unattended</h2>
      <p class="muted">The repository ships a small bot that polls <code>executable()</code> and calls
      <code>executeBatch()</code>. It needs only an RPC URL and a funded key.</p>
      <pre><code>PRIVATE_KEY=0x… npm run keeper</code></pre>
    </section>`;
}

function integrate(): string {
  return `
    <section class="narrow">
      <h1>Integrate</h1>
      <p class="lede">One read tells you whether a wallet is paid up. Use it in a contract, a backend, or a frontend.</p>
      <h2>From a contract</h2>
      <pre><code>interface IStanding {
  function isCurrent(uint256 planId, address payer, uint32 grace)
    external view returns (bool);
}

modifier onlySubscribers() {
  // 3 days of grace before access is cut off
  require(IStanding(${DEPLOYED ? STANDING : "STANDING"}).isCurrent(PLAN_ID, msg.sender, 3 days), "not subscribed");
  _;
}</code></pre>
      <h2>From a backend or frontend</h2>
      <pre><code>import { createPublicClient, http, parseAbi } from "viem";

const client = createPublicClient({ transport: http("${arc.rpcUrls.default.http[0]}") });
const paid = await client.readContract({
  address: "${DEPLOYED ? STANDING : "0x…"}",
  abi: parseAbi(["function isCurrent(uint256,address,uint32) view returns (bool)"]),
  functionName: "isCurrent",
  args: [planId, userAddress, 3 * 86400],
});</code></pre>
      <h2>Reconciliation</h2>
      <p>Pass any 32-byte reference to <code>subscribe(planId, ref)</code> — an order number, a user id. It is
      emitted in the <code>Subscribed</code> event, and every payment emits <code>Paid</code> with the gross
      amount, your net, the protocol fee and the executor fee.</p>
      <h2>Fees</h2>
      <p><code>isCurrent</code> stays true to the end of the last period paid for, even if the subscriber cancels
      early. The grace argument only extends it for wallets that are still subscribed.</p>
      <p>The protocol takes 0.3% of each payment (hard-capped at 1% in the contract). Executors are paid from
      the payment too, never more than the cap you set on the plan.</p>
    </section>`;
}

const notFound = (message = "Page not found.") =>
  `<section class="narrow center"><h1>Nothing here</h1><p class="muted">${message}</p><a class="btn" href="#/">Home</a></section>`;

// ──────────────────────────── actions ────────────────────────────

/** Parse a decimal string into 6-decimal token units, rejecting anything that isn't a plain number. */
function units(text: string): bigint {
  const clean = text.trim();
  if (!/^\d+(\.\d{1,6})?$/.test(clean)) throw new Error(`"${text}" isn't a valid amount.`);
  return parseUnits(clean, 6);
}

async function submitPlan(form: HTMLFormElement, button: HTMLButtonElement) {
  if (!state.address) return connect();
  const f = new FormData(form);
  const amount = units(String(f.get("amount")));
  const tip = units(String(f.get("tip")));
  let cap = units(String(f.get("cap")));
  if (cap > amount / 2n) cap = amount / 2n; // contract rule: the executor never takes more than half
  if (tip > cap) throw new Error("The tip can't be larger than the maximum per payment.");

  await act(button, "Publishing…", async () => {
    const before = await client.readContract({ ...standing, functionName: "planCount" });
    await send({
      ...standing,
      functionName: "createPlan",
      args: [f.get("token") as Address, amount, Number(f.get("period")), tip, cap, String(f.get("name")).trim()],
    });
    const mine = await client.readContract({ ...standing, functionName: "plansOf", args: [state.address!] });
    const id = mine.filter((p) => p >= before).pop() ?? mine[mine.length - 1];
    toast("Plan published. Share the link to start collecting.");
    location.hash = `#/plan/${id}`;
  });
}

/**
 * Approve and subscribe in one transaction through Multicall3From, which keeps the user's wallet
 * as msg.sender for both calls. It only accepts plain EOAs, so smart accounts fall back to two.
 */
async function subscribe(planId: bigint, periods: bigint) {
  const me = state.address!;
  const [plan] = await getPlans([planId]);
  const allowance = await client.readContract({ address: plan.token, abi: erc20Abi, functionName: "allowance", args: [me, STANDING] });
  // The allowance is shared by all of this wallet's subscriptions, so add to it rather than replace it.
  const target = allowance + plan.amount * periods;
  const ref = toHex(`web:${Date.now()}`, { size: 32 });

  const approve = { address: plan.token, abi: erc20Abi, functionName: "approve", args: [STANDING, target] } as const;
  const sub = { ...standing, functionName: "subscribe", args: [planId, ref] } as const;
  const batch = {
    address: MULTICALL3_FROM,
    abi: multicallFromAbi,
    functionName: "aggregate3",
    args: [
      [
        { target: plan.token, allowFailure: false, callData: encodeFunctionData(approve) },
        { target: STANDING, allowFailure: false, callData: encodeFunctionData(sub) },
      ],
    ],
  } as const;

  const batchable = await client.simulateContract({ ...batch, account: me }).then(
    () => true,
    () => false,
  );
  if (batchable) {
    await send(batch);
  } else {
    await send(approve);
    await send(sub);
  }
}

app.addEventListener("submit", (e) => {
  e.preventDefault();
  const form = e.target as HTMLFormElement;
  if (form.id !== "plan-form") return;
  submitPlan(form, form.querySelector("button[type=submit]")!).catch((err) => toast(explain(err), "err"));
});

app.addEventListener("click", (e) => {
  const button = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-action]");
  if (!button) return;
  const { action, id, ids, text } = button.dataset;

  if (action === "connect") return void connect().catch((err) => toast(explain(err), "err"));
  if (action === "disconnect") return disconnect();
  if (action === "copy") return void navigator.clipboard.writeText(text!).then(() => toast("Link copied."));
  if (!state.address) return void connect().catch((err) => toast(explain(err), "err"));

  if (action === "subscribe") {
    const periods = BigInt(document.querySelector<HTMLSelectElement>("#periods")!.value);
    void act(button, "Confirm in wallet…", async () => {
      await subscribe(BigInt(id!), periods);
      toast("Subscribed. First payment sent.");
      await render();
    });
  }
  if (action === "cancel") {
    void act(button, "Cancelling…", async () => {
      await send({ ...standing, functionName: "cancel", args: [BigInt(id!)] });
      toast("Subscription cancelled. No further payments will be taken; time already paid for stays valid.");
      await render();
    });
  }
  if (action === "close") {
    if (!confirm("Close this plan? All subscriptions stop and it can't be reopened.")) return;
    void act(button, "Closing…", async () => {
      await send({ ...standing, functionName: "closePlan", args: [BigInt(id!)] });
      toast("Plan closed.");
      await render();
    });
  }
  if (action === "execute") {
    const list = ids!.split(",").map(BigInt);
    void act(button, "Settling…", async () => {
      await send({ ...standing, functionName: "executeBatch", args: [list] });
      toast(`Settled. Your gas refund and tips are in your wallet.`);
      await render();
    });
  }
});

// ───────────────────────────── router ────────────────────────────

let renderId = 0;

async function view(): Promise<string> {
  const [, route, arg] = (location.hash || "#/").split("/");
  if (!DEPLOYED && route && route !== "integrate") {
    return `<section class="narrow center"><h1>Launching shortly</h1><p class="muted">The contract is being deployed to
      Arc mainnet. Until then you can read how it works and how to integrate.</p>
      <div class="row" style="justify-content:center"><a class="btn" href="#/">How it works</a><a class="btn ghost" href="#/integrate">Integrate</a></div></section>`;
  }
  switch (route ?? "") {
    case "":
      return home();
    case "new":
      return createPlan();
    case "plan":
      return /^\d+$/.test(arg ?? "") ? planPage(BigInt(arg)) : notFound();
    case "account":
      return account();
    case "keeper":
      return keeper();
    case "integrate":
      return integrate();
    default:
      return notFound();
  }
}

async function render() {
  const id = ++renderId;
  // Never leave a blank page while the chain is being read.
  if (!app.firstChild) app.innerHTML = `${header()}<main><p class="empty">Reading from Arc…</p></main>${footer()}`;
  let main: string;
  try {
    main = await view().catch(async () => {
      await new Promise((r) => setTimeout(r, 1200)); // one quiet retry before bothering the visitor
      return view();
    });
  } catch (err) {
    console.error(err);
    main = `<section class="narrow center"><h1>Couldn't load</h1>
      <p class="muted">The app couldn't reach an Arc RPC endpoint from this browser. An ad blocker, VPN or strict
      network filter is the usual cause.</p><p class="muted small">${esc(explain(err))}</p>
      <button class="btn" onclick="location.reload()">Try again</button></section>`;
  }
  if (id !== renderId) return; // a newer navigation finished first
  const prelaunch = DEPLOYED ? "" : `<p class="banner">Preview — the contract is not on Arc mainnet yet, so plans can't be created.</p>`;
  const banner = state.wrongChain ? `<p class="banner">Your wallet is on another network. Actions will ask to switch to Arc.</p>` : "";
  app.innerHTML = `${header()}${prelaunch}${banner}<main>${main}</main>${footer()}`;
}

window.addEventListener("hashchange", () => {
  window.scrollTo(0, 0);
  void render();
});
onWallet(() => void render());
void restore().finally(render);
