import type { ButtonHTMLAttributes, ReactNode } from "react";

type Variant = "default" | "primary" | "gold" | "link";

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
  loading?: boolean;
  children: ReactNode;
};

export function Button({
  variant = "default",
  loading = false,
  disabled,
  children,
  className = "",
  ...props
}: Props) {
  return (
    <button
      {...props}
      className={`btn ${variant === "primary" ? "p" : variant === "gold" ? "g" : variant === "link" ? "link" : ""} ${className}`}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
    >
      {loading ? "Working…" : children}
    </button>
  );
}
