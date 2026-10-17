/**
 * The single error shape used by every route:
 *
 *   { "error": { "code": "NOT_FOUND", "message": "...", "details": ... } }
 *
 * `details` is only ever populated with *validation* output — never with
 * secrets, stack traces, or raw SQL.
 */

export type ErrorCode =
	| "VALIDATION_ERROR"
	| "UNAUTHORIZED"
	| "FORBIDDEN"
	| "NOT_FOUND"
	| "CONFLICT"
	| "CONFIG_ERROR"
	| "AI_UNAVAILABLE"
	| "INTERNAL";

const STATUS_BY_CODE: Record<ErrorCode, number> = {
	VALIDATION_ERROR: 400,
	UNAUTHORIZED: 401,
	FORBIDDEN: 403,
	NOT_FOUND: 404,
	CONFLICT: 409,
	CONFIG_ERROR: 500,
	AI_UNAVAILABLE: 503,
	INTERNAL: 500,
};

export class AppError extends Error {
	readonly code: ErrorCode;
	readonly details?: unknown;

	constructor(code: ErrorCode, message: string, details?: unknown) {
		super(message);
		this.name = "AppError";
		this.code = code;
		this.details = details;
	}

	get status(): number {
		return STATUS_BY_CODE[this.code];
	}

	toResponse(): Response {
		return Response.json(
			{
				error: {
					code: this.code,
					message: this.message,
					...(this.details === undefined ? {} : { details: this.details }),
				},
			},
			{ status: this.status },
		);
	}
}

export const badRequest = (message: string, details?: unknown) =>
	new AppError("VALIDATION_ERROR", message, details);
export const unauthorized = (message = "Authentication required") =>
	new AppError("UNAUTHORIZED", message);
export const forbidden = (message = "You do not have access to this resource") =>
	new AppError("FORBIDDEN", message);
export const notFound = (message = "Resource not found") => new AppError("NOT_FOUND", message);
export const conflict = (message: string) => new AppError("CONFLICT", message);
export const aiUnavailable = (message = "No AI provider is currently available") =>
	new AppError("AI_UNAVAILABLE", message);
