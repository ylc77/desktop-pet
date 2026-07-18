import { emitTo, listen, type Event, type UnlistenFn } from "@tauri-apps/api/event";

export type DesktopControlListener<T> = (payload: T) => void;

export interface DesktopControlTransport {
  listen<T>(eventName: string, listener: DesktopControlListener<T>): Promise<UnlistenFn>;
  emitTo<T>(target: string, eventName: string, payload: T): Promise<void>;
}

export const tauriDesktopControlTransport: DesktopControlTransport = {
  listen: <T>(eventName: string, listener: DesktopControlListener<T>) =>
    listen<T>(eventName, (event: Event<T>) => listener(event.payload)),
  emitTo: <T>(target: string, eventName: string, payload: T) => emitTo(target, eventName, payload),
};
