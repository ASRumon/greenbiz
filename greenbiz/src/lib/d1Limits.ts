/**
 * D1 platform limits that callers must respect.
 *
 * The important one: D1 allows at most **100 bound parameters per statement**.
 * A multi-row `INSERT` binds `rows x columns` parameters, so a naive
 * `insert().values(bigArray)` silently works in tests with a handful of rows and
 * then fails at scale with "too many SQL variables".
 *
 * The seeded catalogue hits this immediately: 14 institutions x 8 columns = 112.
 * Hence chunking.
 */

/** Maximum bound parameters allowed in a single D1 statement. */
export const D1_MAX_BOUND_PARAMS = 100;

/**
 * Splits rows into groups that each bind fewer than `D1_MAX_BOUND_PARAMS`.
 *
 * A safety margin of one row is subtracted so callers can add a parameter or two
 * to the statement without tripping the limit.
 */
export function chunkForInsert<T>(rows: readonly T[], columnCount: number): T[][] {
	if (columnCount <= 0) throw new Error("columnCount must be positive");

	const rowsPerChunk = Math.max(1, Math.floor(D1_MAX_BOUND_PARAMS / columnCount) - 1);

	const chunks: T[][] = [];
	for (let index = 0; index < rows.length; index += rowsPerChunk) {
		chunks.push(rows.slice(index, index + rowsPerChunk));
	}
	return chunks;
}
