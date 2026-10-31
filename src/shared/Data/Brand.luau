--!strict
-- The game's name and where its source lives: change them here and every screen follows (the title
-- screen's wordmark, the Help card's credits and Source line, the landscape prompt).
--
-- This game is a modified version of RoWorld (Snick Co.), itself a modified version of OpenFront, under
-- the GNU AGPL v3 and the additional terms in LICENSE: the credits must keep "© OpenFront and
-- Contributors" visible, the name must not be OpenFront's (nor RoWorld's), and players must be able to
-- get this source (SOURCE_REPO).
local Brand = {}

--- The name, as written in sentences.
Brand.NAME = "Terra"
--- The title screen's wordmark (capitals).
Brand.WORDMARK = "TERRA"
--- The public repository with this game's source (owner/repo on GitHub).
Brand.SOURCE_REPO = "Unproblematical/roworld"
--- Who made this version's changes, and when (the AGPL asks a modified version to say so).
Brand.MODIFIED_BY = "Unproblematical"
Brand.MODIFIED_YEAR = 2026

return Brand
