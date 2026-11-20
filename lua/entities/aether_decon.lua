-- lua/entities/aether_decon.lua
-- ИПП-8: снимает заражение кожи и одежды (иприт, зарин) — ожог и испарения прекращаются.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "aether_antidote_base"
ENT.PrintName = "Decontamination Kit (IPP-8)"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true
ENT.AntidoteKind = "decon"
ENT.Model     = "models/aether/antidote_decon.mdl"
ENT.HintKey   = "hint.antidote_decon"
