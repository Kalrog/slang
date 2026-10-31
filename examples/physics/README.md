# Physics examples

Physics with the `box2d` (2D) and `jolt` (3D) packages, drawn with the
`raylib` package.

```
slang run boxes.slang     2D: a pyramid of boxes; drop boxes and balls, grab and throw them
slang run tower.slang     3D: a tower of boxes; throw balls at it, walk around it
```

`make physics` in the repository runs both. They need raylib and Box2D
installed (`brew install raylib box2d`); Jolt comes with its package.
`PHYSICS_FRAMES=n` quits after n frames.
