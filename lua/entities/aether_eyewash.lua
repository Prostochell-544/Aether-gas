-- lua/entities/aether_eyewash.lua
-- Промывка глаз: слезоточивый газ и аммиак — слёзы и жжение проходят быстро.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "aether_antidote_base"
ENT.PrintName = "Eye Wash"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true
ENT.AntidoteKind = "eyewash"
ENT.Model     = "models/aether/antidote_eyewash.mdl"
ENT.HintKey   = "hint.antidote_eyewash"
