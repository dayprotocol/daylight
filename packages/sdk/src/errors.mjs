export class DayError extends Error {
  /**
   * @param {string} code
   * @param {string} message
   * @param {number} [status]
   * @param {unknown} [body]
   */
  constructor(code, message, status, body) {
    super(message);
    this.name = "DayError";
    this.code = code;
    this.status = status;
    this.body = body;
  }
}

export default DayError;
