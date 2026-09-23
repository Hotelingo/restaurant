import BatchWorkflow from "./BatchWorkflow";

export default async function Page({ params }: { params: Promise<{ batchId: string }> }) {
  const { batchId } = await params;
  return <BatchWorkflow batchId={batchId} />;
}
