import IssueWorkspace from "./IssueWorkspace";

export default async function Page({ params }: { params: Promise<{ reviewId: string; issueId: string }> }) {
  const { reviewId, issueId } = await params;
  return <IssueWorkspace reviewId={reviewId} issueId={issueId} />;
}
