SandboxVars = {
    VERSION = 6,
    -- Changing this also sets the "Population Multiplier" in Advanced Zombie Options. Default = Normal
    -- 1 = Insane
    Zombies = 4,
    -- How zombies are distributed across the map. Default = Urban Focused
    Distribution = 1,
    ZombieVoronoiNoise = true,
    LootItemRemovalList = "",
    WorldItemRemovalList = "Base.Hat, Base.Glasses, Base.Maggots",
    FoodLootNew = 0.8,
    DaysForRottenFoodRemoval = -1,
    -- <BHC> [!] It is recommended that you DO NOT change this. [!] <RGB:1,1,1>   Can be used to adjust.
    RollsMultiplier = 1.0,
    -- How often events during the player's sleep, like nightmares, occur. Default = Never
    SleepingEvent = 1,
    -- If a piece of media hasn't been fully seen or read, show "???".
    MetaKnowledge = 3,
    Basement = {
        -- How frequently basements spawn at random locations. Default = Sometimes
        SpawnFrequency = 4,
    },
    Map = {
        AllowMiniMap = false,
        AllowWorldMap = true,
        MapAllKnown = false,
        MapNeedsLight = true,
    },
    ZombieLore = {
        Speed = 4,
        Strength = 2,
        SpottedLogic = true,
    },
    ZombieConfig = {
        PopulationMultiplier = 0.65,
        RespawnHours = 0.0,
    },
    MultiplierConfig = {
        Global = 1.0,
        GlobalToggle = true,
        Fitness = 1.0,
    },
}
