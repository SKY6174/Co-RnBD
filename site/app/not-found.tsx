export default function NotFoundPage() {
  return (
    <main className="shell" style={{ paddingBlock: "5rem" }}>
      <p className="section-index">404 / PAGE NOT FOUND</p>
      <h1>페이지를 찾을 수 없습니다.</h1>
      <p>주소를 확인하거나 학회 첫 화면에서 다시 시작해 주세요.</p>
      <a className="button button-bright" href="/">학회 홈으로</a>
    </main>
  );
}
