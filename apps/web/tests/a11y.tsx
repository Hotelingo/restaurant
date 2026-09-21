import { JSDOM } from "jsdom";
import { renderToStaticMarkup } from "react-dom/server";
import {
  Button,
  Card,
  Chip,
  DataTable,
  Disclosure,
  EmptyState,
  ErrorPanel,
  Field,
  Select,
  Skeleton,
  Tab,
  Tabs,
} from "../components/ui/index";

function Fixture() {
  const rows = [{ id: "1", label: "Net Sales", value: "228,500" }];

  return (
    <main>
      <h1>Component accessibility fixture</h1>

      <Card title="Controls">
        <Field
          label="Reporting period"
          name="period"
          hint="Use the period shown in the source statement."
          defaultValue="July 2026"
        />
        <Field
          label="Required mapping"
          name="mapping"
          error="Choose one ladder line."
          aria-required="true"
        />
        <Select label="Primary comparator" name="comparator" defaultValue="budget">
          <option value="budget">Budget</option>
          <option value="prior_year">Prior year</option>
        </Select>
        <div>
          <Button type="button" variant="primary">Save</Button>
          <Button type="button" disabled>Unavailable</Button>
          <Button type="button" loading>Processing</Button>
        </div>
      </Card>

      <Tabs label="Review sections">
        <Tab id="tab-overview" controls="panel-overview" selected onSelect={() => undefined}>
          Overview
        </Tab>
        <Tab id="tab-evidence" controls="panel-evidence" selected={false} onSelect={() => undefined}>
          Evidence
        </Tab>
      </Tabs>
      <section role="tabpanel" id="panel-overview" aria-labelledby="tab-overview">
        <p>Overview panel</p>
      </section>
      <section role="tabpanel" id="panel-evidence" aria-labelledby="tab-evidence" hidden>
        <p>Evidence panel</p>
      </section>

      <DataTable
        caption="Financial review sample"
        rows={rows}
        rowKey={(row) => row.id}
        columns={[
          { key: "label", header: "Line", render: (row) => row.label },
          { key: "value", header: "Actual", align: "right", render: (row) => row.value },
        ]}
      />

      <Disclosure summary="Why this matters">
        Supporting explanations are reachable without title-only tooltips.
      </Disclosure>

      <EmptyState
        title="No files yet"
        action={<Button type="button">Add file</Button>}
      >
        Upload a source file to begin.
      </EmptyState>

      <ErrorPanel
        message="The server could not complete this request."
        correlationId="fixture-correlation-id"
        action={<Button type="button">Retry</Button>}
      />

      <div aria-label="Status examples">
        <Chip tone="ok">Validated</Chip>
        <Chip tone="warn">Needs review</Chip>
        <Chip tone="bad">Blocked</Chip>
        <Chip tone="info">Information</Chip>
        <Chip tone="mute">Not calculated</Chip>
      </div>

      <div role="status" aria-label="Loading content" aria-busy="true">
        <Skeleton />
      </div>
    </main>
  );
}

async function main() {
  const markup = renderToStaticMarkup(<Fixture />);
  const dom = new JSDOM(
    `<!doctype html><html lang="en"><head><title>Accessibility fixture</title></head><body>${markup}</body></html>`,
  );
  
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    Document: dom.window.Document,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  });
  
  const axeModule = await import("axe-core");
  const axe = axeModule.default;
  const results = await axe.run(dom.window.document, {
    runOnly: {
      type: "tag",
      values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"],
    },
  });
  
  if (results.violations.length > 0) {
    for (const violation of results.violations) {
      console.error(`[${violation.id}] ${violation.help}`);
      for (const node of violation.nodes) {
        console.error(`  ${node.target.join(" ")}: ${node.failureSummary ?? ""}`);
      }
    }
    process.exitCode = 1;
  } else {
    console.log(`axe: 0 violations across ${results.passes.length} passing rules`);
  }
  
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
