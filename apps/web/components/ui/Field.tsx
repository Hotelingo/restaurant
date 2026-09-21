import {
  forwardRef,
  type InputHTMLAttributes,
  type ReactNode,
} from "react";

type Props = InputHTMLAttributes<HTMLInputElement> & {
  label: string;
  hint?: ReactNode;
  error?: string;
};

export const Field = forwardRef<HTMLInputElement, Props>(function Field(
  { label, hint, error, id, className = "", ...props },
  ref,
) {
  const fieldId = id ?? props.name;
  if (!fieldId) throw new Error("Field requires id or name");

  const hintId = hint ? `${fieldId}-hint` : undefined;
  const errorId = error ? `${fieldId}-error` : undefined;

  return (
    <div className={`fld ${error ? "bad" : ""} ${className}`}>
      <label className="fld-l" htmlFor={fieldId}>
        {label}
      </label>
      <input
        {...props}
        ref={ref}
        id={fieldId}
        aria-invalid={error ? true : undefined}
        aria-describedby={[hintId, errorId].filter(Boolean).join(" ") || undefined}
      />
      {hint ? <div id={hintId} className="hint">{hint}</div> : null}
      {error ? <div id={errorId} className="err">{error}</div> : null}
    </div>
  );
});
