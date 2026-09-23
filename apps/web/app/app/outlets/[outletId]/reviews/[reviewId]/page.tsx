import ReviewWorkspace from "./ReviewWorkspace";

export default async function Page({ params }: { params: Promise<{ reviewId: string }> }) {
  const { reviewId } = await params;
  return <ReviewWorkspace reviewId={reviewId} />;
}
