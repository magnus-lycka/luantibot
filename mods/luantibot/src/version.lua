-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Wire format version. The mod refuses jobs whose `format` it does not
-- recognise; see "Wire contract" in docs/implementation_plan.md.

local version = {}

version.FORMAT = 1

--- Is a job document's declared format version one we can execute?
--- @param format any value from the job document's `format` field
--- @return boolean
function version.supported(format)
    return format == version.FORMAT
end

return version
