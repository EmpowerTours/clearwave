import { explorerUrl } from "@/lib/contracts";

export function Panel({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-xl border border-[var(--border)] bg-[var(--panel)] p-5">
      <h2 className="text-sm font-semibold tracking-wide uppercase text-[var(--muted)]">
        {title}
      </h2>
      {subtitle ? (
        <p className="mt-1 text-sm text-[var(--muted)]">{subtitle}</p>
      ) : null}
      <div className="mt-4">{children}</div>
    </section>
  );
}

export function Row({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-baseline justify-between gap-4 border-b border-[var(--border)] py-2 last:border-0">
      <span className="text-sm text-[var(--muted)]">{label}</span>
      <span className="text-right text-sm font-medium tabular-nums">
        {children}
      </span>
    </div>
  );
}

export function Badge({
  ok,
  children,
}: {
  ok: boolean;
  children: React.ReactNode;
}) {
  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold"
      style={{
        color: ok ? "var(--accent)" : "var(--danger)",
        background: ok ? "rgba(74,222,128,0.10)" : "rgba(248,113,113,0.10)",
        border: `1px solid ${ok ? "rgba(74,222,128,0.30)" : "rgba(248,113,113,0.30)"}`,
      }}
    >
      <span
        className="h-1.5 w-1.5 rounded-full"
        style={{ background: ok ? "var(--accent)" : "var(--danger)" }}
      />
      {children}
    </span>
  );
}

export function Addr({ value, label }: { value: string; label?: string }) {
  return (
    <a
      href={explorerUrl("address", value)}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-xs text-[var(--muted)] underline decoration-dotted underline-offset-4 hover:text-[var(--text)]"
    >
      {label ?? `${value.slice(0, 6)}…${value.slice(-4)}`}
    </a>
  );
}
