# Fixed-Wing Bot Autopilot Summary

This is a game-oriented summary of how to make a fixed-wing aircraft bot change course, maintain flight, and chase moving targets.

## Core Idea

A fixed-wing aircraft should not steer by directly yawing toward a target.

Instead, it should:

```text
course error -> target roll -> ailerons
altitude error -> target pitch -> elevator
speed error -> throttle
yaw rate -> rudder damping
```

The plane turns by banking. Yaw is mostly used for damping or coordinated turn behaviour, not as the main steering axis.

## Basic Autopilot Layers

A practical bot can be split into three layers:

```text
Waypoint / target logic
	outputs target_roll, target_pitch, target_speed

Attitude controller
	outputs aileron, elevator, rudder, throttle

Plane physics
	applies forces / torques
```

This makes the AI easier to tune because navigation and aircraft stability are separate.

## Course Change Toward a Waypoint

Find the flat horizontal direction to the waypoint:

```gdscript
var target_direction = (waypoint_position - plane_position).normalized()
var flat_target_direction = Vector3(target_direction.x, 0.0, target_direction.z).normalized()
var flat_forward = Vector3(-global_basis.z.x, 0.0, -global_basis.z.z).normalized()
```

Find the signed course error:

```gdscript
var course_error = signed_angle(flat_forward, flat_target_direction, Vector3.UP)
```

Convert course error into desired bank angle:

```gdscript
var target_roll = clamp(course_error * roll_gain, -max_bank_angle, max_bank_angle)
```

Then the roll controller moves the aircraft toward that bank angle:

```gdscript
var roll_error = angle_difference(current_roll, target_roll)
var aileron = roll_error * roll_p - roll_rate * roll_d
```

## Pitch / Altitude Control

Use altitude error to choose a target pitch:

```gdscript
var altitude_error = waypoint_position.y - plane_position.y
var target_pitch = clamp(altitude_error * pitch_gain, min_pitch_angle, max_pitch_angle)
```

Then use a pitch controller:

```gdscript
var pitch_error = angle_difference(current_pitch, target_pitch)
var elevator = pitch_error * pitch_p - pitch_rate * pitch_d
```

## Throttle / Speed Control

Throttle should try to maintain cruise speed:

```gdscript
var speed_error = cruise_speed - current_speed
var throttle = clamp(base_throttle + speed_error * throttle_gain, 0.0, 1.0)
```

## Rudder

For a simple game bot, rudder can be optional.

A basic version is just yaw damping:

```gdscript
var rudder = -yaw_rate * yaw_damping
```

This prevents ugly side slipping or oscillation without making yaw the main steering method.

## More Realistic Bank Calculation

Instead of mapping course error directly to roll, you can calculate desired turn rate first:

```gdscript
var desired_turn_rate = clamp(course_error * turn_gain, -max_turn_rate, max_turn_rate)
```

Then convert turn rate into bank angle:

```gdscript
var gravity = 9.81
var target_roll = atan(current_speed * desired_turn_rate / gravity)
target_roll = clamp(target_roll, -max_bank_angle, max_bank_angle)
```

This behaves better because faster aircraft need more bank to turn at the same rate.

## Chasing a Moving Target

Do not steer toward the target's current position.

A moving target should be chased using either:

```text
simple prediction
pure pursuit
lead pursuit
proportional navigation
```

For a game, simple prediction is easiest. Proportional navigation looks better for intercept behaviour.

## Simple Lead Prediction

Estimate where the target will be when the plane reaches it:

```gdscript
var to_target = target_position - plane_position
var distance_to_target = to_target.length()

var time_to_reach = distance_to_target / max(plane_speed, 1.0)

var predicted_target_position = target_position + target_velocity * time_to_reach
```

Then use `predicted_target_position` as the waypoint:

```gdscript
var target_direction = (predicted_target_position - plane_position).normalized()
```

This avoids constant lagging behind the target.

## Proportional Navigation

Proportional navigation is better for intercepts.

The idea:

```text
If the line of sight to the target is rotating, turn in that direction.
If the line of sight stops rotating while distance is closing, you are on an intercept path.
```

Get relative position and velocity:

```gdscript
var relative_position = target_position - plane_position
var relative_velocity = target_velocity - plane_velocity

var distance = relative_position.length()
var line_of_sight = relative_position.normalized()

var closing_speed = -line_of_sight.dot(relative_velocity)
```

Store the previous line of sight and calculate line-of-sight rotation rate:

```gdscript
var los_rotation = previous_line_of_sight.signed_angle_to(line_of_sight, Vector3.UP)
var los_rate = los_rotation / delta

previous_line_of_sight = line_of_sight
```

Calculate desired lateral acceleration:

```gdscript
var navigation_gain = 3.0
var desired_lateral_acceleration = navigation_gain * closing_speed * los_rate
```

Convert that acceleration into target roll:

```gdscript
var gravity = 9.81
var target_roll = atan(desired_lateral_acceleration / gravity)
target_roll = clamp(target_roll, -max_bank_angle, max_bank_angle)
```

Then feed `target_roll` into the same roll controller:

```gdscript
var roll_error = angle_difference(current_roll, target_roll)
var aileron = roll_error * roll_p - roll_rate * roll_d
```

## Altitude While Chasing

For altitude, simple prediction is usually enough:

```gdscript
var time_to_target = distance / max(plane_speed, 1.0)
var predicted_target_position = target_position + target_velocity * time_to_target

var altitude_error = predicted_target_position.y - plane_position.y
var target_pitch = clamp(altitude_error * pitch_gain, min_pitch_angle, max_pitch_angle)
```

## Behaviour Choices

Use different steering depending on the AI behaviour:

```text
intercept / attack target -> proportional navigation
follow target from behind -> chase an offset point behind the target
orbit target -> steer toward a moving point around the target
fly to waypoint -> course error to roll
```

## Recommended First Implementation

Start simple:

```text
1. Make the plane fly level with target_roll = 0 and target_pitch = 0.
2. Add roll control.
3. Add pitch control.
4. Add throttle speed control.
5. Add waypoint following.
6. Add moving target prediction.
7. Replace simple prediction with proportional navigation if needed.
```

The most important part is to make the attitude controller stable first. If the plane cannot hold roll and pitch cleanly, moving target chasing will look bad no matter how good the targeting algorithm is.
