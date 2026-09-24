import Link from "next/link";

const stages = [
  {
    area: "01 · Context",
    title: "Define the review frame",
    text: "Set up the organisation, restaurant outlet, reporting period, operating context and materiality. The review starts with an explicit frame rather than hidden assumptions.",
    items: ["Organisation & outlet", "Reporting context", "Period", "Materiality"],
  },
  {
    area: "02 · Data Centre",
    title: "Bring source data under control",
    text: "Upload files, map source fields to the canonical model, validate exceptions and commit only controlled data into the review.",
    items: ["Upload", "Mapping", "Validation", "Commit"],
  },
  {
    area: "03 · Analysis",
    title: "Explain the financial result",
    text: "Build the management P&L, reconcile it and connect material movements to revenue, food cost, labour and other operating drivers.",
    items: ["Management P&L", "Reconciliation", "Driver analysis", "Traceability"],
  },
  {
    area: "04 · Review",
    title: "Focus management attention",
    text: "Frame the review around material movements, build the issue shortlist and retain evidence for each management conclusion.",
    items: ["FRAME", "Issue shortlist", "Evidence", "Review comments"],
  },
  {
    area: "05 · Actions",
    title: "Convert analysis into decisions",
    text: "Record the decision, owner, lever, guardrail, target trigger, due date and forecast effect so the review produces an operating response.",
    items: ["Decision", "Owner", "Action", "Forecast effect"],
  },
  {
    area: "06 · Owner Pack",
    title: "Close the loop",
    text: "Assemble management statements, reviewer checks and sign-off history into an owner-ready output tied back to the underlying calculations.",
    items: ["Statements", "Review gate", "Pack", "Sign-off history"],
  },
];

export default function TourPage() {
  return (
    <main className="tour-page">
      <header className="landing-nav">
        <Link className="landing-brand" href="/">
          <span className="brand-mark" aria-hidden="true" />
          <span><b>Restaurant Performance Review</b><small>Product tour</small></span>
        </Link>
        <nav className="landing-actions">
          <Link className="btn" href="/">Home</Link>
          <Link className="btn" href="/auth/sign-in">Sign in</Link>
          <Link className="btn p" href="/auth/register">Create account</Link>
        </nav>
      </header>

      <section className="tour-intro">
        <span className="landing-kicker">Public product tour</span>
        <h1>See the review flow before creating an account.</h1>
        <p>
          The application is organised around a single management-review spine:
          context → data → analysis → review → action → owner pack.
        </p>
      </section>

      <section className="tour-flow" aria-label="Restaurant review workflow">
        {stages.map((stage) => (
          <article className="tour-stage" key={stage.area}>
            <div className="tour-stage-area">{stage.area}</div>
            <div className="tour-stage-copy">
              <h2>{stage.title}</h2>
              <p>{stage.text}</p>
              <div className="tour-tags">
                {stage.items.map((item) => <span className="chip mute" key={item}>{item}</span>)}
              </div>
            </div>
          </article>
        ))}
      </section>

      <section className="landing-final tour-final">
        <div>
          <span className="landing-kicker">Continue when ready</span>
          <h2>Create an account to start a controlled review.</h2>
        </div>
        <div className="landing-actions">
          <Link className="btn" href="/auth/sign-in">Sign in</Link>
          <Link className="btn p" href="/auth/register">Create account</Link>
        </div>
      </section>
    </main>
  );
}
