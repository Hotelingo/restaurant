import { EmptyState } from "@/components/ui";

export default function DataCentreEmptyPage() {
  return (
    <main className="shell">
      <div className="panel">
        <div className="page-head">
          <h1>Data Centre</h1>
          <p>Source files enter through controlled ingestion. No financial data has been committed yet.</p>
        </div>
        <EmptyState title="No files uploaded yet">
          Slice 2 will add the R1 templates, mapping reuse, validation queue and commit workflow.
        </EmptyState>
      </div>
    </main>
  );
}
