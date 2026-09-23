import PackWorkspace from "./PackWorkspace";

export default async function Page({ params }: { params: Promise<{ reviewId: string }> }) {
  const { reviewId } = await params;
  return <PackWorkspace reviewId={reviewId} />;
}
