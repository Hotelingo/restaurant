import { forwardRef, type ReactNode, type TextareaHTMLAttributes } from "react";

type Props = TextareaHTMLAttributes<HTMLTextAreaElement> & {
  label: string;
  hint?: ReactNode;
  error?: string;
};

export const TextArea = forwardRef<HTMLTextAreaElement, Props>(function TextArea(
  { label, hint, error, id, className = "", ...props },
  ref,
) {
  const fieldId = id ?? props.name;
  if (!fieldId) throw new Error("TextArea requires id or name");

  const hintId = hint ? `${fieldId}-hint` : undefined;
  const errorId = error ? `${fieldId}-error` : undefined;

  return (
    <div className={`fld ${error ? "bad" : ""} ${className}`}>
      <label className="fld-l" htmlFor={fieldId}>
        {label}
      </label>
      <textarea
        {...props}
        ref={ref}
        id={fieldId}
        className="textarea"
        aria-invalid={error ? true : undefined}
        aria-describedby={[hintId, errorId].filter(Boolean).join(" ") || undefined}
      />
      {hint ? <div id={hintId} className="hint">{hint}</div> : null}
      {error ? <div id={errorId} className="err">{error}</div> : null}
    </div>
  );
});
