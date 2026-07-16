export interface MotionState {
  position: number;
  velocity: number;
  direction: -1 | 1;
}

export interface MotionBounds { minimum: number; maximum: number }
export interface MotionConfig {
  speed: number;
  acceleration: number;
  deceleration: number;
  edgePadding: number;
}

export interface MotionStep extends MotionState { reversed: boolean }

function approach(current: number, target: number, amount: number): number {
  if (current < target) return Math.min(target, current + amount);
  if (current > target) return Math.max(target, current - amount);
  return current;
}

export function stepMotion(state: MotionState, elapsedMs: number, bounds: MotionBounds, config: MotionConfig): MotionStep {
  const seconds = Math.max(0, Math.min(elapsedMs, 100)) / 1000;
  const speed = Math.max(0, config.speed);
  const acceleration = Math.max(1, config.acceleration);
  const deceleration = Math.max(1, config.deceleration);
  const minimum = Math.min(bounds.minimum, bounds.maximum);
  const maximum = Math.max(bounds.minimum, bounds.maximum);
  const edgePadding = Math.min(Math.max(0, config.edgePadding), (maximum - minimum) / 2);
  const minimumPosition = minimum + edgePadding;
  const maximumPosition = maximum - edgePadding;
  if (maximumPosition - minimumPosition <= Number.EPSILON) {
    return { position: minimumPosition, velocity: 0, direction: state.direction, reversed: false };
  }
  const edge = state.direction > 0 ? maximumPosition : minimumPosition;
  const remaining = state.direction > 0 ? edge - state.position : state.position - edge;
  const brakingDistance = (state.velocity * state.velocity) / (2 * deceleration);
  const shouldBrake = remaining <= Math.max(edgePadding * 0.25, brakingDistance);
  const targetVelocity = shouldBrake ? 0 : state.direction * speed;
  const rate = shouldBrake ? deceleration : acceleration;
  let velocity = approach(state.velocity, targetVelocity, rate * seconds);
  let position = state.position + velocity * seconds;
  let direction = state.direction;
  let reversed = false;
  const stoppedAtBrakeTarget = shouldBrake && Math.abs(velocity) <= Math.max(2, deceleration * seconds);

  if (stoppedAtBrakeTarget) {
    position = edge;
    velocity = 0;
    direction = direction === 1 ? -1 : 1;
    reversed = true;
  } else if (position <= minimumPosition || position >= maximumPosition) {
    position = Math.max(minimumPosition, Math.min(maximumPosition, position));
    if (Math.abs(velocity) <= Math.max(2, deceleration * seconds)) {
      velocity = 0;
      direction = direction === 1 ? -1 : 1;
      reversed = true;
    }
  }
  return { position, velocity, direction, reversed };
}
