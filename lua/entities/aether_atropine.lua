-- lua/entities/aether_atropine.lua
-- Автошприц с атропином: зарин — снимает половину дозы, в 4 раза быстрее выводит остаток, втрое слабее вред и судороги 3 минуты. Можно уколоть заранее.
AddCSLuaFile()

ENT.Type      = "anim"
ENT.Base      = "aether_antidote_base"
ENT.PrintName = "Atropine Autoinjector"
ENT.Category  = "Aether Gas"
ENT.Spawnable = true
ENT.AntidoteKind = "atropine"
ENT.Model     = "models/aether/antidote_atropine.mdl"
ENT.HintKey   = "hint.antidote_atropine"
