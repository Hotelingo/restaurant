"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button, Field } from "@/components/ui";
import { useSetupDraft } from "../SetupDraftContext";

function slugify(value: string) {
  return value.toLowerCase().trim().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
}

export default function OrganisationSetupPage() {
  const router = useRouter();
  const { setOrganisation } = useSetupDraft();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugEdited, setSlugEdited] = useState(false);

  function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!name.trim() || !slug.trim()) return;
    setOrganisation({ name: name.trim(), slug: slug.trim() });
    router.push("/setup/outlet");
  }

  return (
    <main className="shell">
      <div className="panel">
        <ol className="stepper" aria-label="Setup progress">
          <li className="cur">1 Organisation</li><li>2 Outlet</li><li>3 Context</li><li>4 Period</li>
        </ol>
        <div className="page-head">
          <h1>Create organisation</h1>
          <p>The business name stays customer-facing; the slug is only a technical identifier.</p>
        </div>
        <form onSubmit={submit} className="stack">
          <Field
            label="Organisation name"
            name="organisation-name"
            value={name}
            onChange={(event) => {
              setName(event.target.value);
              if (!slugEdited) setSlug(slugify(event.target.value));
            }}
            required
          />
          <Field
            label="URL-safe slug"
            name="organisation-slug"
            value={slug}
            pattern="[a-z0-9]+(?:-[a-z0-9]+)*"
            onChange={(event) => { setSlugEdited(true); setSlug(event.target.value); }}
            hint="Lowercase letters, numbers and hyphens."
            required
          />
          <Button type="submit" variant="primary">Continue to outlet</Button>
        </form>
      </div>
    </main>
  );
}
