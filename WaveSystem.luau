-- Discord: stickman2883 | Roblox: Alawi81 

local Players = game:GetService("Players") -- Player joins and character access come from here.
local PathfindingService = game:GetService("PathfindingService") -- This computes routes around walls.
local RunService = game:GetService("RunService") -- The heartbeat updates active enemy behavior.
local Debris = game:GetService("Debris") -- Temporary effects are cleaned up without manual tracking.
local CollectionService = game:GetService("CollectionService") -- Tags make spawned enemies easy to find.
local Workspace = game:GetService("Workspace") -- The arena and raycasts live in the 3D world.
local Lighting = game:GetService("Lighting") -- A little lighting setup makes the demo easier to read.

local CONFIG = { -- Keeping the tuning values together makes balancing less annoying.
	Intermission = 7, -- Seconds between waves.
	BaseEnemies = 3, -- Starting enemy count before wave scaling.
	EnemiesPerWave = 2, -- Extra enemies added for each new wave.
	SpawnDelay = 0.8, -- Short pause between enemy spawns.
	EnemySpeed = 10, -- Normal enemy walking speed.
	BossSpeed = 8, -- Bosses are slower but harder to defeat.
	EnemyHealth = 55, -- Starting health for regular enemies.
	HealthPerWave = 12, -- Extra health per wave.
	TouchDamage = 12, -- Damage dealt when an enemy gets close enough.
	AttackRange = 4.5, -- Distance where the enemy can hit a player.
	AttackCooldown = 1.3, -- Time between enemy attacks.
	SightDistance = 90, -- Maximum distance used for line-of-sight checks.
	RepathDelay = 1.1, -- How often an enemy refreshes its route.
	BossEvery = 5, -- Every fifth wave includes a boss.
	BossHealthMultiplier = 5, -- Boss health relative to the normal enemy.
	ArenaSize = 150, -- Width and depth of the generated arena.
} 

local random = Random.new() -- A local random generator keeps spawn offsets varied.
local arenaFolder = Instance.new("Folder") -- Generated demo parts are grouped together.
arenaFolder.Name = "WaveDemoArena" -- A clear name helps identify the generated map.
arenaFolder.Parent = Workspace

local enemyFolder = Instance.new("Folder") -- Enemies get their own folder for cleanup and inspection.
enemyFolder.Name = "WaveEnemies" -- This name is visible in Explorer while testing.
enemyFolder.Parent = Workspace

local waveNumber = 0 -- The wave manager increments this when a new wave starts.
local activeEnemies = {} -- This set tracks living enemy objects by their model.
local running = true -- The main loop checks this flag before starting another wave.


local function makePart(name, size, cframe, color, material, parent) -- Shared part creation avoids repeated setup code.
	local part = Instance.new("Part") -- Roblox parts provide the physical arena pieces.
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic -- Most parts use a simple material by default.
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent or arenaFolder -- A parent argument lets this helper make parts in other folders.
	return part
end

local function buildArena() -- This creates the demo space so the script works in an empty place.
	local half = CONFIG.ArenaSize / 2 -- Half-size makes it easy to place walls symmetrically.
	makePart("ArenaFloor", Vector3.new(CONFIG.ArenaSize, 2, CONFIG.ArenaSize), CFrame.new(0, -1, 0), Color3.fromRGB(48, 55, 62), Enum.Material.Slate) -- The floor sits with its top at y=0.
	makePart("NorthWall", Vector3.new(CONFIG.ArenaSize, 18, 3), CFrame.new(0, 8, -half), Color3.fromRGB(70, 80, 91), Enum.Material.Concrete) 
	makePart("SouthWall", Vector3.new(CONFIG.ArenaSize, 18, 3), CFrame.new(0, 8, half), Color3.fromRGB(70, 80, 91), Enum.Material.Concrete) 
	makePart("WestWall", Vector3.new(3, 18, CONFIG.ArenaSize), CFrame.new(-half, 8, 0), Color3.fromRGB(70, 80, 91), Enum.Material.Concrete) 
	makePart("EastWall", Vector3.new(3, 18, CONFIG.ArenaSize), CFrame.new(half, 8, 0), Color3.fromRGB(70, 80, 91), Enum.Material.Concrete) 
	makePart("CenterMarker", Vector3.new(12, 0.25, 12), CFrame.new(0, 0.13, 0), Color3.fromRGB(35, 170, 135), Enum.Material.Neon) -- The marker shows the center of the arena.
	makePart("CoverA", Vector3.new(10, 8, 4), CFrame.new(-24, 4, -15), Color3.fromRGB(95, 105, 118), Enum.Material.Concrete) -- Cover gives pathfinding something to route around.
	makePart("CoverB", Vector3.new(4, 8, 12), CFrame.new(22, 4, 18), Color3.fromRGB(95, 105, 118), Enum.Material.Concrete) -- A second obstacle makes the arena less empty.
	makePart("CoverC", Vector3.new(12, 5, 4), CFrame.new(15, 2.5, -30), Color3.fromRGB(95, 105, 118), Enum.Material.Concrete) -- Low cover creates another path choice.
	for index = 1, 4 do -- Four corner lights make the arena easy to see.
		local x = (index % 2 == 0) and (half - 12) or (-half + 12) -- Alternating signs place lights on opposite sides.
		local z = (index <= 2) and (half - 12) or (-half + 12) -- The second coordinate picks the other pair of corners.
		local lamp = makePart("ArenaLamp", Vector3.new(2, 12, 2), CFrame.new(x, 6, z), Color3.fromRGB(40, 200, 170), Enum.Material.Neon) -- The pole is just a visible landmark.
		local light = Instance.new("PointLight") -- A point light adds a little local illumination.
		light.Brightness = 1.2
		light.Range = 28
		light.Parent = lamp
	end
	Lighting.ClockTime = 18
	Lighting.Brightness = 2
end

buildArena() -- Build the demo environment before any enemies spawn.

local function getLivingCharacter(player) -- This helper filters out players who have not spawned or are dead.
	local character = player.Character -- Character models can be replaced after respawning.
	if not character then -- A player may join before their character exists.
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") -- Humanoids expose health and movement state.
	local root = character:FindFirstChild("HumanoidRootPart") -- The root is the best point for distance and movement math.
	if not humanoid or not root or humanoid.Health <= 0 then -- All three conditions are needed for a valid target.
		return nil
	end
	return character, humanoid, root
end

local function findNearestTarget(origin) -- Enemies use this to choose the closest living player.
	local bestCharacter = nil -- No target is selected at the start.
	local bestHumanoid = nil -- Keep the target humanoid alongside the character.
	local bestRoot = nil -- Keep the root for path and facing calculations.
	local bestDistance = math.huge -- Any real distance should beat this initial value.
	for _, player in Players:GetPlayers() do -- Only connected players can be targets.
		local character, humanoid, root = getLivingCharacter(player) -- Skip players who are not alive.
		if character and root then -- Continue only when the helper found a valid target.
			local distance = (root.Position - origin).Magnitude 
			if distance < bestDistance then -- Keep the nearest valid character.
				bestDistance = distance
				bestCharacter = character
				bestHumanoid = humanoid
				bestRoot = root
			end
		end
	end
	return bestCharacter, bestHumanoid, bestRoot, bestDistance
end

local function hasLineOfSight(enemyModel, targetCharacter, origin, targetPosition) -- A ray checks whether a wall blocks the chase.
	local direction = targetPosition - origin -- Ray direction is the offset from enemy to target.
	if direction.Magnitude > CONFIG.SightDistance then -- Long rays are unnecessary for this demo.
		return false
	end
	local params = RaycastParams.new() -- RaycastParams lets the query ignore selected instances.
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {enemyModel} -- The ray should start checking beyond the enemy's own model.
	params.IgnoreWater = true
	local result = Workspace:Raycast(origin, direction, params) 
	if not result then -- Nothing blocked the ray before its endpoint.
		return true
	end
	return result.Instance:IsDescendantOf(targetCharacter)
end

local Enemy = {} -- This table stores shared methods for every enemy instance.
Enemy.__index = Enemy

function Enemy.new(wave, isBoss, spawnPosition) -- The constructor creates one enemy object and its visible model.
	local self = setmetatable({}, Enemy) -- The metatable makes this table behave like an Enemy instance.
	self.Wave = wave
	self.IsBoss = isBoss
	self.Alive = true
	self.LastAttack = 0
	self.LastPath = 0
	self.Waypoints = {} -- The current route is stored here between path calculations.
	self.WaypointIndex = 1
	self.BlockedConnection = nil
	self.Model = Instance.new("Model") -- A model groups the body and its humanoid together.
	self.Model.Name = isBoss and ("MiniBoss_Wave_" .. wave) or ("Enemy_Wave_" .. wave) -- Names make wave testing easier.
	self.Model.Parent = enemyFolder
	self.Root = Instance.new("Part") -- A simple block body keeps this example self-contained.
	self.Root.Name = "HumanoidRootPart" -- Humanoid movement expects a root part with this name.
	self.Root.Size = isBoss and Vector3.new(5, 7, 5) or Vector3.new(3, 5, 3) -- Boss size makes it easy to recognize.
	self.Root.CFrame = CFrame.new(spawnPosition) -- CFrame places the enemy at its spawn point.
	self.Root.Color = isBoss and Color3.fromRGB(210, 65, 75) or Color3.fromRGB(220, 145, 65) -- Red marks bosses and orange marks regular enemies.
	self.Root.Material = Enum.Material.SmoothPlastic
	self.Root.Anchored = false
	self.Root.CanCollide = true
	self.Root.Parent = self.Model
	self.Model.PrimaryPart = self.Root
	local humanoid = Instance.new("Humanoid") -- The Humanoid supplies health and MoveTo behavior.
	humanoid.Name = "Humanoid" -- The default name is familiar in Roblox tools.
	humanoid.MaxHealth = (CONFIG.EnemyHealth + wave * CONFIG.HealthPerWave) * (isBoss and CONFIG.BossHealthMultiplier or 1) -- Health rises with waves and bosses get a multiplier.
	humanoid.Health = humanoid.MaxHealth
	humanoid.WalkSpeed = isBoss and CONFIG.BossSpeed or (CONFIG.EnemySpeed + math.min(wave * 0.25, 5)) -- Speed scales gently without becoming unreasonable.
	humanoid.HipHeight = isBoss and 1.5 or 0.5 -- Adjusting hip height helps the block body sit above the floor.
	humanoid.Parent = self.Model
	self.Humanoid = humanoid
	self.Root:SetNetworkOwner(nil) -- The server owns enemy physics so all players see consistent movement.
	self.Model:SetAttribute("Wave", wave) -- Attributes make the enemy wave visible to debugging tools.
	self.Model:SetAttribute("IsBoss", isBoss) -- The boss state is also available without reading the Lua table.
	CollectionService:AddTag(self.Model, "WaveEnemy") -- A tag lets other systems find all enemies later.
	if isBoss then -- Bosses get a simple visible marker above their body.
		local marker = Instance.new("BillboardGui") -- BillboardGui faces the camera automatically.
		marker.Name = "BossMarker" -- The marker can be found easily while debugging.
		marker.Size = UDim2.fromOffset(150, 34) -- Keep the marker compact.
		marker.StudsOffset = Vector3.new(0, 5, 0) -- Float it above the boss's head.
		marker.AlwaysOnTop = true
		marker.Parent = self.Root
		local label = Instance.new("TextLabel") -- The label shows the boss status.
		label.Size = UDim2.fromScale(1, 1) 
		label.BackgroundTransparency = 1
		label.Text = "MINI BOSS"
		label.TextColor3 = Color3.fromRGB(255, 90, 90) -- Bright red stands out from the arena.
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.Parent = marker
	end
	self.Humanoid.Died:Connect(function() -- The death event handles cleanup once the health reaches zero.
		self:Destroy() -- Use the shared cleanup method to remove the model and tracking entry.
	end)
	activeEnemies[self.Model] = self
	return self
end

function Enemy:Face(position) -- This turns the body toward a target using CFrame math.
	if not self.Root or not self.Root.Parent then -- A removed root cannot be rotated.
		return
	end
	local current = self.Root.Position -- Keep the enemy's current world position.
	local flatTarget = Vector3.new(position.X, current.Y, position.Z) -- Removing vertical difference keeps the body upright.
	if (flatTarget - current).Magnitude > 0.05 then -- Avoid a lookAt call when both points are almost identical.
		self.Root.CFrame = CFrame.lookAt(current, flatTarget) 
	end
end

function Enemy:ComputePath(destination) -- Pathfinding is refreshed instead of recalculated every frame.
	if os.clock() - self.LastPath < CONFIG.RepathDelay then -- Rate limiting avoids wasting server time.
		return
	end
	self.LastPath = os.clock() -- Record when this attempt started.
	local path = PathfindingService:CreatePath({ -- Agent settings help Roblox estimate walkable routes.
		AgentRadius = self.IsBoss and 3 or 2, -- The boss needs a wider route through obstacles.
		AgentHeight = self.IsBoss and 8 or 6, -- Give the path solver enough vertical clearance.
		AgentCanJump = true, -- Allow jumps when the navmesh requires them.
		AgentJumpHeight = 7, -- Set a modest jump height for the demo.
		AgentMaxSlope = 35, -- Avoid routes that are too steep for the enemy.
		WaypointSpacing = 5, -- Fewer waypoints make the route easier to follow.
	}) 
	local success = pcall(function() -- A path request can fail if the destination is unreachable.
		path:ComputeAsync(self.Root.Position, destination) -- Ask Roblox to calculate a route from the enemy to the target.
	end)
	if not success or path.Status ~= Enum.PathStatus.Success then -- Failed paths should not replace a usable route.
		self.Waypoints = {} -- Clear stale points so the AI can fall back to direct movement.
		self.WaypointIndex = 1
		return
	end
	self.Waypoints = path:GetWaypoints() -- Store the new route for later heartbeat updates.
	self.WaypointIndex = math.min(2, #self.Waypoints) -- Skip the first point because it is usually near the enemy already.
	if self.BlockedConnection then -- A previous path can still have a Blocked connection.
		self.BlockedConnection:Disconnect() -- Disconnecting prevents old paths from triggering new logic.
		self.BlockedConnection = nil
	end
	self.BlockedConnection = path.Blocked:Connect(function(blockedIndex) -- Roblox reports when a waypoint becomes blocked.
		if blockedIndex >= self.WaypointIndex then -- Only a blockage ahead of the enemy matters.
			self.LastPath = 0
		end
	end)
end

function Enemy:MoveToward(targetRoot) -- This follows waypoints or uses a direct fallback when no route exists.
	if not targetRoot or not targetRoot.Parent then -- The target may have respawned or disappeared.
		return
	end
	self:ComputePath(targetRoot.Position) -- Refresh the route when the repath timer allows it.
	local waypoint = self.Waypoints[self.WaypointIndex] -- Read the next route point, if one exists.
	if waypoint then -- A successful path gives the enemy a waypoint to follow.
		if (self.Root.Position - waypoint.Position).Magnitude < 3 then -- Advance when close enough to the current point.
			self.WaypointIndex += 1
			waypoint = self.Waypoints[self.WaypointIndex]
		end
	end
	if waypoint then -- Keep following the route while points remain.
		if waypoint.Action == Enum.PathWaypointAction.Jump then -- Some routes require jumping over small obstacles.
			self.Humanoid.Jump = true
		end
		self.Humanoid:MoveTo(waypoint.Position) -- Humanoid movement handles the physics of walking to the point.
	else
		self.Humanoid:MoveTo(targetRoot.Position) -- Direct movement is a simple fallback until a new path is ready.
	end
	self:Face(targetRoot.Position) -- Rotate toward the target after choosing a movement destination.
end

function Enemy:Attack(targetHumanoid, distance) -- The enemy can damage a player only within range and cooldown.
	if distance > CONFIG.AttackRange then -- Do not attack targets that are still too far away.
		return
	end
	if os.clock() - self.LastAttack < CONFIG.AttackCooldown then -- Prevent damage every heartbeat.
		return
	end
	self.LastAttack = os.clock() -- Store the time of this attack.
	local damage = self.IsBoss and CONFIG.TouchDamage * 2 or CONFIG.TouchDamage -- Boss attacks hurt more than normal attacks.
	targetHumanoid:TakeDamage(damage) -- TakeDamage respects Roblox Humanoid health behavior.
end

function Enemy:Update() -- One update chooses a target, checks visibility, then moves or attacks.
	if not self.Alive or not self.Model.Parent or self.Humanoid.Health <= 0 then -- Dead objects should not do more AI work.
		return
	end
	local character, targetHumanoid, targetRoot, distance = findNearestTarget(self.Root.Position) -- Pick the nearest living player.
	if not character or not targetRoot then -- There may be no players alive in the server.
		self.Humanoid:MoveTo(self.Root.Position) -- Stop requesting movement while waiting for a target.
		return
	end
	local origin = self.Root.Position + Vector3.new(0, self.Root.Size.Y * 0.25, 0) -- Raise the ray origin slightly above the body center.
	local visible = hasLineOfSight(self.Model, character, origin, targetRoot.Position) -- Check if cover blocks the enemy's view.
	if visible then -- Clear sight allows direct pursuit and attack checks.
		self:Face(targetRoot.Position) -- Keep the enemy facing the player even while standing still.
		if distance <= CONFIG.AttackRange then -- Close targets can be attacked.
			self:Attack(targetHumanoid, distance) -- The method handles the attack cooldown and damage.
		else
			self.Humanoid:MoveTo(targetRoot.Position) -- Direct pursuit is efficient when there is no wall in the way.
		end
	else
		self:MoveToward(targetRoot) -- Pathfinding handles the obstacle while keeping the target as destination.
	end
end

function Enemy:Destroy() -- Cleanup removes event connections and the model from the wave tracker.
	if not self.Alive then -- Death and manual cleanup can happen close together.
		return
	end
	self.Alive = false
	if self.BlockedConnection then -- A route event may still be connected.
		self.BlockedConnection:Disconnect() -- Disconnect it before removing the model.
		self.BlockedConnection = nil
	end
	if self.Model then -- The model may already have been removed externally.
		activeEnemies[self.Model] = nil
		CollectionService:RemoveTag(self.Model, "WaveEnemy") -- Clear the tag so other systems do not find a dead enemy.
		self.Model:Destroy() -- Remove the body and Humanoid from the world.
		self.Model = nil
	end
end

local function getSpawnPosition() -- Spawn points are chosen around the outer edge of the arena.
	local half = CONFIG.ArenaSize / 2 - 12 -- Leave space between the spawn and the wall.
	local side = random:NextInteger(1, 4) -- Choose one of the four arena edges.
	local offset = random:NextNumber(-half + 10, half - 10) -- Randomize the position along the selected edge.
	if side == 1 then -- North edge.
		return Vector3.new(offset, 5, -half)
	elseif side == 2 then
		return Vector3.new(offset, 5, half)
	elseif side == 3 then
		return Vector3.new(-half, 5, offset)
	else
		return Vector3.new(half, 5, offset)
	end
end

local function countActiveEnemies() -- Count only entries that still represent living enemy objects.
	local count = 0 -- Start with no active enemies.
	for model, enemy in activeEnemies do -- Iterate the tracked enemy table.
		if enemy.Alive and model.Parent then -- Ignore stale entries whose model is gone.
			count += 1
		else
			activeEnemies[model] = nil
		end
	end
	return count
end

local function announce(message) -- Output gives a simple demonstration log without requiring a UI script.
	print("[Wave Demo] " .. message) -- The server output shows intermissions, waves, and boss notices.
end

local function spawnWave(wave) -- This spawns the number of enemies for the requested wave.
	local enemyCount = CONFIG.BaseEnemies + ((wave - 1) * CONFIG.EnemiesPerWave) -- Each wave adds more enemies.
	local hasBoss = wave % CONFIG.BossEvery == 0 -- Modulo identifies every fifth wave.
	announce("Wave " .. wave .. " starting: " .. enemyCount .. " enemies.") -- Log the regular enemy count.
	if hasBoss then -- Boss waves get a separate announcement.
		announce("Mini boss incoming!") -- Make the fifth-wave event obvious in the output.
	end
	for index = 1, enemyCount do -- Spawn each regular enemy with a small delay.
		if not running then -- Stop cleanly if the script is being shut down.
			return
		end
		Enemy.new(wave, false, getSpawnPosition()) -- Create the next regular enemy.
		task.wait(CONFIG.SpawnDelay) -- Stagger spawns so the server does not create everything at once.
	end
	if hasBoss then -- The mini boss appears after the regular group.
		Enemy.new(wave, true, getSpawnPosition()) -- Boss stats are selected by the constructor.
	end
end

local function waitForPlayers() -- Waves only start when at least one player is connected.
	while running and #Players:GetPlayers() == 0 do -- Keep checking while the server is empty.
		task.wait(1) -- A one-second wait avoids a busy loop.
	end
end

Players.PlayerAdded:Connect(function(player) -- This callback runs whenever a player joins.
	announce(player.Name .. " joined the wave arena.") -- Log joins so the demo is easy to follow.
	player.CharacterAdded:Connect(function(character) -- CharacterAdded also fires after respawn.
		local humanoid = character:WaitForChild("Humanoid", 10) -- Wait briefly for the character's health controller.
		if humanoid then -- The character may fail to load fully.
			humanoid.Died:Connect(function() -- Track deaths for the server demo log.
				announce(player.Name .. " was knocked out.") -- The player can respawn and rejoin the fight.
			end)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player) -- This callback runs when a player leaves.
	announce(player.Name .. " left the wave arena.") -- The AI will naturally retarget the remaining players.
end)

RunService.Heartbeat:Connect(function() -- Heartbeat runs on the server after each physics step.
	for _, enemy in activeEnemies do -- Update each living enemy once per heartbeat.
		if enemy.Alive then -- Avoid calling methods on enemies already being cleaned up.
			enemy:Update() -- Target selection, vision, pathing, facing, and attacks happen here.
		end
	end
end)

task.spawn(function() -- Run the wave manager separately so it does not block event callbacks.
	waitForPlayers() -- Wait for the first player before starting the demo.
	while running do -- Continue generating waves for as long as this script is active.
		waveNumber += 1
		announce("Intermission: " .. CONFIG.Intermission .. " seconds before wave " .. waveNumber .. ".") -- Give players time to prepare.
		task.wait(CONFIG.Intermission) -- Wait before spawning the next group.
		if not running then -- Check the stop flag again after the wait.
			break
		end
		spawnWave(waveNumber) -- Create the enemies for this wave.
		while running and countActiveEnemies() > 0 do -- Wait until every enemy is defeated.
			task.wait(0.5) -- Polling twice per second is enough for the wave manager.
		end
		if running then -- Do not announce a clear if the script is stopping.
			announce("Wave " .. waveNumber .. " cleared!") -- The wave is over when no enemies remain.
		end
	end
end)

game:BindToClose(function() -- Roblox calls this when the server is shutting down.
	running = false
	for _, enemy in activeEnemies do -- Walk the remaining tracked enemies.
		enemy:Destroy() -- Remove each enemy and its event connection.
	end
	if arenaFolder then -- The generated arena may still exist during shutdown.
		Debris:AddItem(arenaFolder, 0) -- Debris safely schedules the arena folder for removal.
	end
end)
