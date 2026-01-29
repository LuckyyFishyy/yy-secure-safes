-- Helper functions for yy-secure-safes client
local M = {}

function M.LoadSafeModel(model)
    if not model then return end
    local hash = (type(model) == 'string') and GetHashKey(model) or model
    -- if not IsModelInCdimage(hash) then
    --     print('^1[yy-secure-safes] Model not in CD image: ' .. tostring(model) .. '^7')
    --     return
    -- end
    if HasModelLoaded(hash) then return end
    RequestModel(hash)
    local start = GetGameTimer()
    while not HasModelLoaded(hash) and (GetGameTimer() - start) < 5000 do
        Wait(10)
    end
    if not HasModelLoaded(hash) then
        print('^1[yy-secure-safes] Failed to load model: ' .. tostring(model) .. '^7')
    end
end

return M
