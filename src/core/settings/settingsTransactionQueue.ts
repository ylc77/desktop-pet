/**
 * A small FIFO used by the main window to make whole-document settings writes
 * behave as one transaction stream. A rejected operation never poisons later
 * work, and every mutation reads canonical state only after it reaches the
 * front of this queue.
 */
export class SettingsTransactionQueue {
  private tail: Promise<void> = Promise.resolve();

  run<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation, operation);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }
}
