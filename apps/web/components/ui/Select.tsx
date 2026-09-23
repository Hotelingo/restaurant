import {
  forwardRef,
  type ReactNode,
  type SelectHTMLAttributes,
} from "react";

type Props = SelectHTMLAttributes<HTMLSelectElement> & {
  label: string;
  hint?: ReactNode;
  error?: string;
};

export const Select = forwardRef<HTMLSelectElement, Props>(function Select(
  { label, hint, error, id, className = "", children, ...props },
  ref,
) {
  const fieldId = id ?? props.name;
  if (!fieldId) throw new Error("Select requires id or name");

  const hintId = hint ? `${fieldId}-hint` : undefined;
  const errorId = error ? `${fieldId}-error` : undefined;

  return (
    <div className={`fld ${error ? "bad" : ""} ${className}`}>
      <label className="fld-l" htmlFor={fieldId}>
        {label}
      </label>
      <select
        {...props}
        ref={ref}
        id={fieldId}
        aria-invalid={error ? true : undefined}
        aria-describedby={[hintId, errorId].filter(Boolean).join(" ") || undefined}
      >
        {children}
      </select>
      {hint ? <div id={hintId} className="hint">{hint}</div> : null}
      {error ? <div id={errorId} className="err">{error}</div> : null}
    </div>
  );
});
