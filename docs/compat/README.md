# Compatibility notes (Mac vs Windows)

One file per area (`lua.md`, `audio.md`, `plugins.md`, …). They are compiled into `docs/COMPATIBILITY.md`.
Record every place where a skin behaves differently on Deskset (macOS) than in Rainmeter (Windows), and every
judgment call where the manual is silent. Use this format for each entry:

```
### <Feature / option / bang / plugin>
- Windows (Rainmeter): <documented behaviour, with manual URL>
- Mac (Deskset): <what we do>
- Why: <macOS limitation / no equivalent API / permission / judgment call>
- Skin impact: <what a skin author or user will notice; workaround if any>
- Status: identical | emulated | partial | not supported
```

Only describe behaviour from the public manual (https://docs.rainmeter.net/manual/) and observed skin files —
never from Rainmeter's source code.
