type LogFields = Record<string, string | number | boolean | null | undefined>;

export function errorCode(error: unknown): string {
  if (!(error instanceof Error)) return "unknown_error";
  return error.message.match(/^[a-z0-9_-]+/i)?.[0]?.toLowerCase() ?? "unknown_error";
}

export function logError(event: string, fields: LogFields = {}): void {
  console.error({ event, ...fields });
}
