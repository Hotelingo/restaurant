import Link from "next/link";

const capabilities = [
  {
    title: "Management P&L",
    text: "Turn restaurant financial data into a structured management view with variance, profitability and reconciliation context.",
  },
  {
    title: "Food cost & operations",
    text: "Connect sales, purchasing, inventory and operating drivers so financial movements can be traced to operational causes.",
  },
  {
    title: "Evidence-led review",
    text: "Move from material movements to issues, decisions, actions and owner-ready review packs with an auditable trail.",
  },
];

const workflow = [
  ["1", "Set up", "Create the organisation, outlet, reporting context and period."],
  ["2", "Load data", "Upload source files, map fields, validate and commit controlled facts."],
  ["3", "Analyse", "Run the P&L and operating calculations, then reconcile the result."],
  ["4", "Frame review", "Apply materiality and focus the review on movements that deserve management attention."],
  ["5", "Decide", "Capture issues, evidence, decisions, owners, actions and forecast implications."],
  ["6", "Report", "Generate the owner pack, complete review checks and retain the signed history."],
];

export default function Home() {
  return (
    <main className="landing">
      <header className="landing-nav">
        <Link className="landing-brand" href="/" aria-label="Restaurant Performance Review home">
          <span className="brand-mark" aria-hidden="true" />
          <span>
            <b>Restaurant Performance Review</b>
            <small>Evidence-led financial review</small>
          </span>
        </Link>
        <nav className="landing-actions" aria-label="Public navigation">
          <Link className="btn" href="/tour">Take a tour</Link>
          <Link className="btn" href="/auth/sign-in">Sign in</Link>
          <Link className="btn p" href="/auth/register">Create account</Link>
        </nav>
      </header>

      <section className="landing-hero">
        <div className="landing-hero-copy">
          <span className="landing-kicker">Restaurant finance, connected to operational evidence</span>
          <h1>Review performance. Explain movement. Turn findings into action.</h1>
          <p>
            Restaurant Performance Review brings financial statements, operating drivers,
            management review and action tracking into one controlled workflow.
          </p>
          <div className="landing-hero-actions">
            <Link className="btn p landing-cta" href="/tour">Explore how it works</Link>
            <Link className="btn landing-cta" href="/auth/register">Create an account</Link>
          </div>
          <p className="landing-note">No account is required to view the product tour.</p>
        </div>

        <div className="landing-preview" aria-label="Review workflow preview">
          <div className="landing-preview-head">
            <span>Monthly review</span>
            <span className="chip ok">Evidence ready</span>
          </div>
          <div className="landing-preview-grid">
            <div><small>Net sales</small><strong>100%</strong><span>review base</span></div>
            <div><small>Food cost</small><strong>Material</strong><span>driver analysis</span></div>
            <div><small>Operating profit</small><strong>Reconciled</strong><span>statement to action</span></div>
          </div>
          <div className="landing-preview-line">
            <span>Data</span><i />
            <span>Analysis</span><i />
            <span>Decision</span><i />
            <span>Owner pack</span>
          </div>
        </div>
      </section>

      <section className="landing-section" id="capabilities">
        <div className="landing-section-head">
          <span className="landing-kicker">One review spine</span>
          <h2>From source data to management action</h2>
          <p>The application keeps the financial result, evidence and management response connected.</p>
        </div>
        <div className="landing-card-grid">
          {capabilities.map((item) => (
            <article className="landing-card" key={item.title}>
              <h3>{item.title}</h3>
              <p>{item.text}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="landing-section landing-workflow" id="workflow">
        <div className="landing-section-head">
          <span className="landing-kicker">Review workflow</span>
          <h2>Six steps, one controlled management review</h2>
        </div>
        <div className="landing-steps">
          {workflow.map(([number, title, text]) => (
            <article className="landing-step" key={number}>
              <span className="landing-step-no">{number}</span>
              <div><h3>{title}</h3><p>{text}</p></div>
            </article>
          ))}
        </div>
        <div className="landing-center">
          <Link className="btn p landing-cta" href="/tour">Open the product tour</Link>
        </div>
      </section>

      <section className="landing-final">
        <div>
          <span className="landing-kicker">Ready to use the workspace?</span>
          <h2>Sign in when you are ready to work with your restaurant data.</h2>
        </div>
        <div className="landing-actions">
          <Link className="btn" href="/auth/sign-in">Sign in</Link>
          <Link className="btn p" href="/auth/register">Create account</Link>
        </div>
      </section>
    </main>
  );
}
