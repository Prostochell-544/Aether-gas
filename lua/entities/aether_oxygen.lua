-- lua/entities/aether_oxygen.lua
-- Кислородный баллончик: угарный газ, углекислота, азот — гипоксия проходит быстрее.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "aether_antidote_base"
ENT.PrintName = "Oxygen Can"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true
ENT.AntidoteKind = "oxygen"
ENT.Model     = "models/aether/antidote_oxygen.mdl"
ENT.HintKey   = "hint.antidote_oxygen"
