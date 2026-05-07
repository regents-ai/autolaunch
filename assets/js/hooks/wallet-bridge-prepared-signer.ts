export function assertPreparedSigner(
  account: `0x${string}`,
  expectedSigner?: `0x${string}` | null,
): void {
  if (!expectedSigner) return

  if (account.toLowerCase() !== expectedSigner.toLowerCase()) {
    throw new Error("Switch to the expected wallet, then try again.")
  }
}
