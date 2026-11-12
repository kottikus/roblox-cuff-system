# 🛡️ Advanced Server-Authoritative Cuff System for Roblox

A highly secure, optimized, and physical-based cuffing/detention system designed for Roblox Roleplay and Tactical games. Built from scratch with a strict server-authoritative architecture to completely mitigate exploiters and physics glitches.

## 🚀 Key Technical Features

* **Server-Authoritative Validation:** The server never trusts the client. Distance checks, cooldowns, and tool equipping are strictly verified on the server-side before execution.
* **Exploit Mitigation:** Contains an active `integrityStep` heartbeat loop running on `RunService.Heartbeat` to constantly monitor physics drift, character changes, and automatically roll back any client-side speed/jump exploits while cuffed.
* **Advanced Physics-Based Dragging:** Utilizes `AlignPosition` and `AlignOrientation` mechanics combined with dynamic **Network Ownership** swapping (`SetNetworkOwner(nil)` to server, then to officer). This guarantees buttery-smooth character interpolation without lag, clipping, or fling bugs.
* **Rig Agnostic Arm Posing:** Features a clean mathematical solution that overwrites the `Motor6D.C0` joints rather than updating `Transform` every frame. Works flawlessly on both **R6** and **R15** avatar types out of the box.
* **Memory Leak Protection:** Full runtime cleanup of constraints, events, and player states upon disconnection, tools un-equipping, or character resetting.

## 📂 Project Structure

* `src/Server/CuffService.lua` - Core backend framework, validation, physics handlers, and data states.
* `src/Server/CuffBootstrap.server.lua` - Server initialization and custom game rule hook injection.
* `src/Client/HandcuffsClient.client.lua` - Local performance optimization, local ProximityPrompts rendering, and inputs.
* `src/Shared/CuffConfig.luau` - Central configuration file containing explicit tuning values.

## 🛠️ Quick Setup & Usage

To integrate the module into your game backend:

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local CuffService = require(ServerScriptService:WaitForChild("CuffService"))

-- Initialize the system remotes and listeners
CuffService.Init()
```

## 📄 License
Distributed under the MIT License. See `LICENSE` for more information.
