-- 二阶堂ヒロ 人格 Lua（严格按 SkillSettings.md）
-- 调用：Modular/TIMING:<时机>/LUA:nikaidou_hiro/LUAMAIN:<函数>(Self)

local SELF, TARGET = "Self", "MainTarget"   -- Modular 目标枚举是 MainTarget，不是 Target
local WF   = "WitchFactor"
local WZ   = "Witchization"
local REB  = "Rebuttal"
local RW   = "Rewind"
local RWW  = "RewindWitch"
local RS   = "RitualSword"
local LAC  = "Laceration"
local COMB = "Combustion"
local PROT = "Protection"
local ADU  = "AttackDmgUp"
local STR  = "Enhancement"       -- [强壮]/Attack Power Up：攻击技能最终威力+1；回溯-魔女化复活时获得
local ATL  = "AttackUp"          -- [攻击等级提升]/Offense Level Up(AtkAdderByStack，Volatile)：与中指希斯克里夫同款，每层(强度)+1攻击等级，仅本回合
local AGI  = "Agility"           -- [迅捷]/Haste(SpeedAdderAsStack)：每层(强度)+1速度，仅本回合
local REP   = "Repose"           -- [安息]
local RMARK = "ReposeMark"       -- 安息固伤的隐形计数标记(无 iconId，叠在敌方目标上供原生 ...MaxHpRatio 脚本读取)
local PRIDE = 5                  -- bonusdmg 的傲慢罪孽编号
local SP_CORROSION = -45         -- 理智触底进入原版 E.G.O 侵蚀（精神崩溃）的阈值
local SP_DELIV     = -35         -- 魔女化下理智≤-35 触发「解脱」转化
local REPOSE_MAX   = 13          -- 安息满层 → 触发「魔女安息仪式」转化
local REPOSE_TEST_BASE = 0       -- 测试用基础安息层数
local DELIV  = 9750121           -- 三技能-特殊：这只是为了让你们得到解脱
local RITUAL = 9750122           -- 三技能-特殊：魔女安息仪式
local DEF_NORMAL = 9750104       -- 常态守备：普通防御
local DEF_WITCH  = 9750114       -- 魔女化守备：闪避

-- setdata 键
local D_SP        = 3001   -- 上次同步的理智值
local D_SP_INIT   = 3002   -- 理智追踪是否已初始化
local D_FIRST_WZ  = 3003   -- 是否已首次魔女化
local D_PENDING   = 3004   -- 待复活类型 0无 1回溯 2回溯魔女化
local D_REB_SKILL = 3005   -- 本回合技能反驳已施加
local D_REB_DEF   = 3006   -- 本回合守备反驳已施加
local D_EVADE     = 3007   -- 本回合闪避回理智次数
local D_DEF_SP    = 3008   -- 本回合「守备-魔女化·回合结束」降理智已触发（所有触发共享一次）
local D_WANT_DELIV  = 3009  -- 本回合是否转化出「解脱」(0/1)；需魔女化
local D_WANT_RITUAL = 3014  -- 本回合是否转化出「魔女安息仪式」(0/1)；与解脱独立、可同回合并存
local D_DELIV_PEND = 3010  -- 解脱因侵蚀延后到下回合
local D_REPOSE_LOCK = 3011 -- 安息仪式后：自身无法再获得[安息]
local D_REPOSE_ACC = 3012   -- 安息的累积部分：侵蚀友方 / 使用侵蚀EGO
local D_REPOSE_OWNER = 3013 -- 带「我带着一切答案」的希罗标记，供友方监听被动回找
local D_RS_LAC_STACK_HELD = 3015 -- 仪礼剑额外触发流血前，临时保存目标流血强度
local D_RS_LAC_TURN_HELD  = 3016 -- 仪礼剑额外触发流血前，临时保存目标流血次数
local D_APPEAR = 3017 -- 当前外观标记：0未初始化/需强制同步，1魔女化，2常态，3安息仪式桑丘
local D_BGM_MODE = 3018 -- 本回合希罗特殊技 BGM：0无，1魔女安息，2大希王处刑曲
local D_DELIV_BGM_HELD = 3019 -- 连续可用的「解脱」是否已播过获得 BGM
local D_RITUAL_BGM_HELD = 3020 -- 连续可用的「魔女安息仪式」是否已播过获得 BGM
local D_DELIV_BGM_NEW = 3021 -- 本回合「解脱」是否刚获得
local D_RITUAL_BGM_NEW = 3022 -- 本回合「魔女安息仪式」是否刚获得

local BGM_REPOSE = 1
local BGM_EXEC   = 2

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function st(unit, kw)  return getbuff(unit, kw, "stack") end   -- 强度/层
local function ct(unit, kw)  return getbuff(unit, kw, "turn")  end   -- 次数
local function unitdata(unit, key)
    return getdata(unit, key) or 0
end
local function data(key)
    return unitdata(SELF, key)
end

local function set_hiro_appearance(is_witch, force)
    if appearance == nil then return end
    -- 死亡单位仍会进入 AfterSlots/RoundStart 被动；此时换回主外观会把死亡动作刷新成 idle。
    -- OnDie 已把 D_APPEAR 清零，真正复活并恢复 HP 后会自然重新同步。
    if gethp(SELF, "normal") <= 0 then return end
    if is_witch then
        if not force and data(D_APPEAR) == 1 then return end
        appearance(SELF, "!custom_8172_MaouHeathclif_MainAppearance")
        setdata(SELF, D_APPEAR, 1)
    else
        if not force and data(D_APPEAR) == 2 then return end
        appearance(SELF, "!custom_8164_MaouHeathclif_DeadRabbitsAppearance")
        setdata(SELF, D_APPEAR, 2)
    end
end

local function set_hiro_ritual_appearance(force)
    if appearance == nil then return end
    if not force and data(D_APPEAR) == 3 then return end
    appearance(SELF, "!custom_1079_Sancho_BerserkAppearance")
    setdata(SELF, D_APPEAR, 3)
end

local function current_skill_id()
    if getskillid == nil then return 0 end
    if pcall == nil then return getskillid() end
    local ok, v = pcall(getskillid)
    if ok and type(v) == "number" then return v end
    return 0
end

-- getstat 安全封装：当前引擎不支持该 statName（或 pcall 缺失/getstat 抛错）时统一返回 0，
-- 避免某个 stat 不被 MT 版插件识别时静默崩溃。调用方需自行处理「返回 0」的退化语义。
local function safestat(unit, name)
    if pcall == nil then return 0 end
    local ok, v = pcall(getstat, unit, name)
    if ok and type(v) == "number" then return v end
    return 0
end

local function play_hiro_bgm(mode)
    if mode <= 0 or data(D_BGM_MODE) == mode then return end

    local ok = 0
    if mode == BGM_EXEC then
        ok = safestat(SELF, "HiroPlayBgmExecution")
    elseif mode == BGM_REPOSE then
        ok = safestat(SELF, "HiroPlayBgmRepose")
    end
    if ok == 1 then setdata(SELF, D_BGM_MODE, mode) end
end

local function play_hiro_voice(stat)
    safestat(SELF, stat)
end

local function restore_hiro_bgm()
    safestat(SELF, "HiroRestoreBgm")
    setdata(SELF, D_BGM_MODE, 0)
end

local function play_special_bgm(got_deliv, got_ritual)
    if got_deliv then
        play_hiro_bgm(BGM_EXEC)
    elseif got_ritual then
        play_hiro_bgm(BGM_REPOSE)
    end
end

local function mark_special_bgm_grant(want, held_key, new_key)
    if want then
        if data(held_key) == 0 then setdata(SELF, new_key, 1) end
    else
        setdata(SELF, held_key, 0)
    end
end

local function play_new_special_bgm(got_deliv, got_ritual)
    local new_deliv = got_deliv and data(D_DELIV_BGM_NEW) == 1
    local new_ritual = got_ritual and data(D_RITUAL_BGM_NEW) == 1

    if got_deliv then setdata(SELF, D_DELIV_BGM_HELD, 1) end
    if got_ritual then setdata(SELF, D_RITUAL_BGM_HELD, 1) end
    play_special_bgm(new_deliv, new_ritual)
end

local function sync_hiro_defense(is_witch, refresh_visual)
    local defense_id = is_witch and DEF_WITCH or DEF_NORMAL

    -- 不走 MT 的 changedefense / SetOverrideDefense：二者都会把传入值污染到防御等级显示。
    -- DLL 侧只同步默认守备选择与已装备/残留在仪表盘里的希罗守备技能。
    if is_witch then
        safestat(SELF, "HiroSyncWitchDefense")
    else
        safestat(SELF, "HiroSyncNormalDefense")
    end
    if refresh_visual ~= false and refreshallslotvisual ~= nil then
        if pcall ~= nil then pcall(refreshallslotvisual) else refreshallslotvisual() end
    end
end

-- 「魔女单位」= 单位 keyword 列表含 "Witch"(希罗人格同款 unitKeyword)。
-- haskey 查的是 unitKeywordList(实证 Lemuen haskey(Target,OR,Laterano) 查自定义 unitKeyword)。
local function is_witch_unit(unit)
    if haskey == nil then return false end
    local ok, v = pcall(haskey, unit, "OR", "Witch")
    return ok and v == 1
end

-- E.G.O 侵蚀中：理智触底(-45)，把技能槽/守备交还原版侵蚀系统，魔女化换牌逻辑全部让位
local function is_corroding()
    return getsp(SELF) <= SP_CORROSION
end

local function gain_factor(n)
    if n > 0 then buff(SELF, WF, n, 0, 0) end
end

-- 「场上每有一名敌方单位计1层」：NoParts99 排除部位/核心，但**包含友方**，
-- 故必须再按阵营过滤——getunitfaction：0=敌方，1=罪人/支援(友方)。
local function enemy_count()
    local units = selecttargets("NoParts99")
    if units == nil then return 0 end
    local n = 0
    for _, u in ipairs(units) do
        local state = getunitstate(u)
        local fac = (getunitfaction ~= nil) and getunitfaction(u) or -1
        if (state == 1 or state == 2) and safestat(u, "isRetreated") ~= 1 and fac == 0 then
            n = n + 1
        end
    end
    return n
end

local function repose_current_count()
    local n = enemy_count()
    if st(SELF, WZ) > 0 then n = n + 1 end
    local allies = selecttargets("AllyExceptSelf99")
    if allies ~= nil then
        for _, u in ipairs(allies) do
            if st(u, WZ) > 0 then n = n + 1 end
        end
    end
    return clamp(n, 0, REPOSE_MAX)
end

local function set_repose_total_for(unit, total)
    total = clamp(total, 0, REPOSE_MAX)
    local diff = total - st(unit, REP)
    if diff ~= 0 then buff(unit, REP, diff, 0, 0) end
end

local function sync_repose_for(unit)
    if unitdata(unit, D_REPOSE_LOCK) == 1 then return end
    set_repose_total_for(unit, REPOSE_TEST_BASE + repose_current_count() + unitdata(unit, D_REPOSE_ACC))
end

local function sync_repose()
    sync_repose_for(SELF)
end

local function add_repose_acc_to(unit, n)
    if unit == nil or unitdata(unit, D_REPOSE_LOCK) == 1 or n <= 0 then return end
    setdata(unit, D_REPOSE_ACC, clamp(unitdata(unit, D_REPOSE_ACC) + n, 0, REPOSE_MAX))
    sync_repose_for(unit)
end

local function add_repose_acc(n)
    add_repose_acc_to(SELF, n)
end

local function corroding_friendly_count()
    local n = 0
    if getsp(SELF) <= SP_CORROSION then n = n + 1 end
    local allies = selecttargets("AllyExceptSelf99")
    if allies ~= nil then
        for _, u in ipairs(allies) do
            if getsp(u) <= SP_CORROSION then n = n + 1 end
        end
    end
    return n
end

local function find_repose_owner()
    if unitdata(SELF, D_REPOSE_OWNER) == 1 then return SELF end
    local allies = selecttargets("AllyExceptSelf99")
    if allies ~= nil then
        for _, u in ipairs(allies) do
            if unitdata(u, D_REPOSE_OWNER) == 1 then return u end
        end
    end
    return nil
end

-- 自身理智下降→魔女因子：
-- 外因导致的实时理智下降由 NikaidouHiro.dll 的 OnChangeMp 补丁直接追踪；
-- Lua 这里只维护基准值，避免回合开始再次补算造成重复获得因子。
local function sync_sp()
    setdata(SELF, D_SP, getsp(SELF))
    setdata(SELF, D_SP_INIT, 1)
end

local function drain_sp(n)               -- 主动失去 n 理智，按实际损失给因子
    if n <= 0 then return end
    local before = getsp(SELF)
    if before <= SP_CORROSION then sync_sp(); return end
    safestat(SELF, "HiroSuppressNextMpFactor")
    healsp(SELF, -n)
    local after = getsp(SELF)
    if before > after then gain_factor(before - after) end
    setdata(SELF, D_SP, after)
    setdata(SELF, D_SP_INIT, 1)
end

local function heal_self_sp(n)           -- 恢复理智（不给因子），重同步
    if n <= 0 then return end
    healsp(SELF, n)
    setdata(SELF, D_SP, getsp(SELF))
    setdata(SELF, D_SP_INIT, 1)
end

-- 施加反驳：夹取到最大 5
local function inflict_rebuttal(unit, amount)
    local room = 5 - st(unit, REB)
    local add = clamp(amount, 0, room)
    if add > 0 then buff(unit, REB, add, 0, 0) end
end

-- 致命伤害触发[回溯]/[回溯-魔女化]后消耗层数 → +20 因子/层。
-- 首次魔女化时的[回溯]→[回溯-魔女化]是转化，不走这里。
local function lose_rewind(kw, n)
    if n <= 0 then return end
    buff(SELF, kw, -n, 0, 0)
    if kw == RW or kw == RWW then gain_factor(20 * n) end
end

local function clear_stagger()
    deactivebreak(SELF, -1, true)
    breakrecover(SELF)
end

local function clear_negatives()
    destroybuff(SELF, "Negative", 0, 99, 1)
end

local function is_indiscriminate_id(id)
    return id == 9750131 or id == 9750132 or id == 9750133
end

local function each_unit(fn)
    fn(SELF)
    local allies = selecttargets("AllyExceptSelf99")
    if allies ~= nil then
        for _, u in ipairs(allies) do fn(u) end
    end
    local enemies = selecttargets("Enemy99")
    if enemies ~= nil then
        for _, u in ipairs(enemies) do fn(u) end
    end
end

local function consume_all_witch_factor()
    local total = 0
    each_unit(function(u)
        local wf = st(u, WF)
        if wf > 0 then
            total = total + wf
            buff(u, WF, -wf, 0, 0)
        end
    end)
    return total
end

------------------------------------------------------------------
-- 被动：大魔女的诅咒
------------------------------------------------------------------

-- 命中+3 / 击杀+10 魔女因子（OnSucceedAttack）
function hiro_hit()
    if getunitstate(TARGET) == 0 then
        gain_factor(10)
    else
        gain_factor(3)
    end
end

function hiro_gain_factor_1()
    gain_factor(1)
end

function hiro_gain_factor_2()
    gain_factor(2)
end

-- 首次魔女化效果
local function first_witchization()
    if data(D_FIRST_WZ) == 1 then return end
    setdata(SELF, D_FIRST_WZ, 1)

    local sp = getsp(SELF)
    if sp > -20 then                          -- 理智设为 -20（仅下调；按 spec 不因此效果获得[魔女因子]）
        safestat(SELF, "HiroSuppressNextMpFactor")
        healsp(SELF, -20 - sp)
        setdata(SELF, D_SP, getsp(SELF))      -- 同步追踪值，避免随后 sync_sp 把这次下降算成因子
        setdata(SELF, D_SP_INIT, 1)
    end

    clear_stagger()                          -- 清除所有混乱条

    local rw = st(SELF, RW)                   -- 回溯 → 回溯-魔女化
    if rw > 0 then
        buff(SELF, RW, -rw, 0, 0)
        buff(SELF, RWW, rw, 0, 0)
    end

    buff(SELF, RS, 1, 0, 0)                   -- 获得仪礼剑
    play_hiro_voice("HiroPlayVoiceFirstWitch")
end

-- 魔女化触发与状态维持（RoundStart）
function hiro_curse_rs()
    setdata(SELF, D_REB_SKILL, 0)
    setdata(SELF, D_REB_DEF, 0)
    setdata(SELF, D_EVADE, 0)
    setdata(SELF, D_DEF_SP, 0)

    -- 先结算致命伤的回溯，再允许魔女化把普通回溯转换掉。
    if data(D_PENDING) ~= 0 or gethp(SELF, "normal") <= 1 then
        hiro_revive()
    end

    -- 按当前回溯状态重设免死（RoundStart 主动清）：Immortal 时机在"已免死"时不再触发，
    -- 不在此处重置则 setimmortal(1) 会在失去回溯后粘连 → 永不死亡（锁血老 bug）。
    if st(SELF, RWW) > 0 or st(SELF, RW) > 0 then setimmortal(1) else setimmortal(0) end

    sync_sp()                                -- 自身外部理智损失 → 因子

    -- 首次触发魔女化：理智≤-20 或 魔女因子≥50
    if st(SELF, WZ) == 0 and data(D_FIRST_WZ) == 0 then
        if getsp(SELF) <= -20 or st(SELF, WF) >= 50 then
            buff(SELF, WZ, 1, 0, 0)
            first_witchization()
        end
    end

    -- 魔女化状态维持
    local w = st(SELF, WZ)
    set_hiro_appearance(w > 0)
    if w > 0 then
        if getsp(SELF) > 0 then drain_sp(getsp(SELF)) end          -- 理智不高于0
        drain_sp(clamp(math.floor(w / 2), 0, 25))                  -- 回合开始降(层/2)理智
        -- 回合开始：获得(层/2)层[攻击等级提升](≤5)与[迅捷](≤3)，均为本回合关键词Buff，不累积
        -- (数值放强度字段、turn=0；施加[迅捷]后须 refreshspeed 才即时改速度，与原版/Vespa一致)
        local half = math.floor(w / 2)
        local lvl  = clamp(half, 0, 5)
        local agi  = clamp(half, 0, 3)
        if lvl > 0 then buff(SELF, ATL, lvl, 0, 0) end
        if agi > 0 then buff(SELF, AGI, agi, 0, 0); refreshspeed(SELF) end
        -- 物理三抗封顶到×0.5(耐性)已并入 [Witchization] buff 本体
        -- (ability OverwriteAtkResistResultIfHigher value0.5，原版 KnightBless 同款)，
        -- 只要魔女化在身就生效，无需每回合单独再给抗性 buff。
    end

    if not is_corroding() then
        sync_hiro_defense(w > 0, false)
    end
end

-- 回合结束魔女化层数增长（EndBattle）
function hiro_curse_eb()
    if st(SELF, WZ) > 0 then
        buff(SELF, WZ, 1 + math.floor(st(SELF, WF) / 10), 0, 0)
    end
end

-- 行动槽阶段：加算↔减算↔无差别 技能替换（AfterSlots）
function hiro_skill_phase()
    local w = st(SELF, WZ)
    set_hiro_appearance(w > 0)
    if is_corroding() then return end   -- 侵蚀中：交还技能槽/守备给原版侵蚀系统，避免换牌把仪表盘卡死
    if w > 0 then
        local s1, s2, s3 = 9750111, 9750112, 9750113
        if w >= 50 then s1, s2, s3 = 9750131, 9750132, 9750133 end
        -- 全槽：把 基础/无差别/残留特殊 统一成对应魔女技能
        skillslotreplace("All", 9750101, s1)
        skillslotreplace("All", 9750111, s1)
        skillslotreplace("All", 9750131, s1)
        skillslotreplace("All", 9750102, s2)
        skillslotreplace("All", 9750112, s2)
        skillslotreplace("All", 9750132, s2)
        skillslotreplace("All", 9750103, s3)
        skillslotreplace("All", 9750113, s3)
        skillslotreplace("All", 9750133, s3)
        skillslotreplace("All", DELIV, s1)     -- 清掉残留的特殊技能(下面只在 slot0 重新放)
        skillslotreplace("All", RITUAL, s1)
        -- 转化基础技能为特殊技能：解脱与安息仪式可同回合并存(各转化一张基础技能，
        -- 由 DLL ReplaceFirstBaseSkill 依次替换最左侧的两张基础技能)。
        local got_deliv = false
        local got_ritual = false
        if data(D_WANT_DELIV) == 1 then got_deliv = safestat(SELF, "HiroReplaceDeliverance") == 1 end
        if data(D_WANT_RITUAL) == 1 then got_ritual = safestat(SELF, "HiroReplaceRitual") == 1 end
        play_new_special_bgm(got_deliv, got_ritual)
        sync_hiro_defense(true)
    else
        skillslotreplace("All", 9750111, 9750101)
        skillslotreplace("All", 9750131, 9750101)
        skillslotreplace("All", 9750112, 9750102)
        skillslotreplace("All", 9750132, 9750102)
        skillslotreplace("All", 9750113, 9750103)
        skillslotreplace("All", 9750133, 9750103)
        skillslotreplace("All", DELIV, 9750101)
        skillslotreplace("All", RITUAL, 9750101)
        -- 安息仪式可在常态(非魔女化)获取；解脱需魔女化(hiro_answer_rs 仅在 WZ>0 设 D_WANT_DELIV)。
        local got_ritual = false
        if data(D_WANT_RITUAL) == 1 then got_ritual = safestat(SELF, "HiroReplaceRitual") == 1 end
        play_new_special_bgm(false, got_ritual)
        sync_hiro_defense(false)
    end
end

------------------------------------------------------------------
-- 被动：死亡回溯（免死 + 复活）
------------------------------------------------------------------

-- 致命伤害时保命并标记待复活（Immortal）
function hiro_immortal()
    if st(SELF, RWW) > 0 then
        setimmortal(1)
        setdata(SELF, D_PENDING, 2)
    elseif st(SELF, RW) > 0 then
        setimmortal(1)
        setdata(SELF, D_PENDING, 1)
    else
        setimmortal(0)
        setdata(SELF, D_PENDING, 0)
    end
end

-- 下回合开始复活（RoundStart）。pending 优先，血量≤1 作兜底
function hiro_revive()
    local pending = data(D_PENDING)
    if pending == 0 and gethp(SELF, "normal") <= 1 then
        if st(SELF, RWW) > 0 then pending = 2
        elseif st(SELF, RW) > 0 then pending = 1 end
    end
    if pending == 0 then return end

    if pending == 2 then
        healhp(SELF, "100%")
        clear_stagger()
        clear_negatives()
        buff(SELF, STR, 1, 0, 0)
        lose_rewind(RWW, 1)
    else
        local pct = clamp(st(SELF, WF) + 30, 0, 80)
        healhp(SELF, tostring(pct) .. "%")
        clear_stagger()
        clear_negatives()
        lose_rewind(RW, 1)
    end
    setdata(SELF, D_PENDING, 0)
end

------------------------------------------------------------------
-- 被动：审判开庭
------------------------------------------------------------------

function hiro_ritual_keep_form()
    if current_skill_id() == RITUAL then set_hiro_appearance(st(SELF, WZ) > 0, true) end
end

function hiro_judge_clash()
    hiro_ritual_keep_form()
    if st(TARGET, REB) > 0 then clash(2) end
end

-- ChangeTakeDamage（TARGET=攻击者）：综合 审判开庭(带反驳单位+20%) / 安息(每层±2%) / EGO侵蚀技能(-80%)。
-- 合并到一处、只调一次 setdmgtaken——多个 ChangeTakeDamage 钩子各调一次会互相覆盖。
function hiro_judge_taken()
    local dmg = getdmg()
    if dmg <= 0 then return end
    local mult = 1.0
    if st(TARGET, REB) > 0 then mult = mult * 1.2 end                 -- 审判开庭：来自带反驳单位+20%
    local rep = st(SELF, REP)
    if rep > 0 then
        local per = (st(SELF, WZ) > 0) and -0.02 or 0.02             -- 安息：魔女化下-2%/层，否则+2%/层
        mult = mult * (1.0 + per * rep)
    end
    local ego = (getskillegotype ~= nil) and getskillegotype(TARGET) or 0
    if ego == 2 or ego == 3 or ego == 4 then mult = mult * 0.2 end    -- 受EGO侵蚀技能伤害-80%
    if mult ~= 1.0 then
        local r = math.floor(dmg * mult)
        if r < 0 then r = 0 end
        setdmgtaken(r)
    end
end

------------------------------------------------------------------
-- 被动：恐怕，再也回不去了（持有 暴怒×2 傲慢×2）
------------------------------------------------------------------

function hiro_fear_rs()
    if st(SELF, WZ) == 0 or st(SELF, RWW) > 0 then return end

    if getsp(SELF) < 0 then
        buff(SELF, PROT, 1, 0, 0)
        buff(SELF, ADU, 1, 0, 0)
    end
    local a = selecttargets("AllyExceptSelf99")
    if a == nil then return end
    for _, u in ipairs(a) do
        healsp(u, -10)
        if getsp(u) < 0 then
            buff(u, PROT, 1, 0, 0)
            buff(u, ADU, 1, 0, 0)
        end
    end
end

------------------------------------------------------------------
-- 支援被动：除掉邪恶（持有 暴怒×5）
------------------------------------------------------------------

function hiro_support_clash()
    local focused = 0
    if isfocused ~= nil then focused = isfocused() end
    if not (focused == 1 or getsp(TARGET) < 0) then return end

    local my = getsp(SELF)
    local a = selecttargets("AllyExceptSelf99")
    if a ~= nil then
        for _, u in ipairs(a) do
            if getsp(u) < my then return end
        end
    end
    clash(1)
    dmgmult(10)
end

------------------------------------------------------------------
-- 技能：使用时威力 + 各技能专属效果（WhenUse）
------------------------------------------------------------------

function hiro_power()
    local id = current_skill_id()
    local wf = st(SELF, WF)
    local sum = st(TARGET, COMB) + st(TARGET, LAC)

    -- 仪礼剑：对异想体/理智<0敌人伤害+10%；对「魔女单位」(unitKeyword 含 Witch)伤害+50%
    if st(SELF, RS) > 0 then
        local focused = 0
        if isfocused ~= nil then focused = isfocused() end
        if focused == 1 or getsp(TARGET) < 0 then dmgmult(10) end
        if is_witch_unit(TARGET) then dmgmult(50) end
    end

    if id == 9750101 then
        -- 硬币/基础威力改用技能原生 power-adder(见 Hiro-Skills.json)，上仪表盘
    elseif id == 9750102 then
        -- 硬币/基础威力改用技能原生 power-adder(见 Hiro-Skills.json)，上仪表盘
    elseif id == 9750103 then
        gain_factor(5)
        wf = st(SELF, WF)
        local reb = st(TARGET, REB)
        if reb > 0 then
            makeunbreakable("all")
            dmgmult(clamp(reb * 10, 0, 50))
        end
    elseif id == 9750111 or id == 9750131 then
        drain_sp(clamp(5 + math.floor(st(SELF, WZ) / 5), 0, 7))
    elseif id == 9750112 or id == 9750132 then
        drain_sp(clamp(5 + math.floor(st(SELF, WZ) / 5), 0, 10))
    elseif id == 9750113 or id == 9750133 then
        local reb = st(TARGET, REB)
        if reb > 0 then dmgmult(clamp(reb * 10, 0, 50)) end
        drain_sp(clamp(5 + math.floor(st(SELF, WZ) / 5), 0, 10))
    elseif id == 9750121 then
        -- 解脱：获得10层魔女化；魔女化超出50每层+1%伤害(最多50)；sum/6基础(最多4)；wf/10最终(最多10)；失理智(最多10)
        setdata(SELF, D_DELIV_BGM_HELD, 0)
        setdata(SELF, D_DELIV_BGM_NEW, 0)
        buff(SELF, WZ, 10, 0, 0)
        local w = st(SELF, WZ)
        if w > 50 then dmgmult(clamp(w - 50, 0, 50)) end
        drain_sp(clamp(5 + math.floor(st(SELF, WZ) / 5), 0, 10))
    elseif id == 9750122 then
        -- 安息仪式：消耗[仪礼剑]+100%伤害；消耗所有[安息]每层+1基础(最多13)；wf/10最终(最多10)；
        -- 失理智(最多15、不低于-40)。[魔女因子]在硬币命中时消耗。
        if st(SELF, RS) > 0 then destroybuff(SELF, RS, 0, 99, 1); dmgmult(100) end
        local rep = st(SELF, REP)
        if rep > 0 then
            base(clamp(rep, 0, 13))
            buff(SELF, REP, -rep, 0, 0)
            setdata(SELF, D_REPOSE_ACC, 0)
        end
        -- 安息固伤：消耗所有单位[魔女因子]→按总量给每个敌方目标叠 mark 层隐形标记[ReposeMark]，
        -- 由硬币上的原生 GiveAdditionalDmgViaEachTargetBuffStackAndMaxHpRatio 读取，
        -- 对各目标「各自生命上限 × mark%」打出独立追加伤害(里卡多式；mark=总消耗/10、≤50；value 0.01=每层1%)。
        local total = consume_all_witch_factor()
        local mark = clamp(math.floor(total / 10), 0, 50)
        if mark > 0 then
            local foes = selecttargets("Enemy99")
            if foes ~= nil then
                for _, u in ipairs(foes) do buff(u, RMARK, mark, 0, 0) end
            end
        end
        local d = clamp(5 + math.floor(st(SELF, WZ) / 5), 0, 15)
        local cur = getsp(SELF)
        if cur - d < -40 then d = cur + 40 end          -- 不低于 -40
        if d > 0 then drain_sp(d) end
    end
end

function hiro_ritual_visual()
    if current_skill_id() == RITUAL then set_hiro_ritual_appearance(true) end
end

function hiro_voice_skill()
    local id = current_skill_id()
    if id == 9750101 then
        play_hiro_voice("HiroPlayVoiceNormalS1")
    elseif id == 9750102 then
        play_hiro_voice("HiroPlayVoiceNormalS2")
    elseif id == 9750103 then
        play_hiro_voice("HiroPlayVoiceNormalS3")
    elseif id == 9750111 or id == 9750131 then
        play_hiro_voice("HiroPlayVoiceWitchS1")
    elseif id == 9750112 or id == 9750132 then
        play_hiro_voice("HiroPlayVoiceWitchS2")
    elseif id == 9750113 or id == 9750133 then
        play_hiro_voice("HiroPlayVoiceWitchS3")
    elseif id == DELIV then
        play_hiro_voice("HiroPlayVoiceDeliverance")
    elseif id == RITUAL then
        play_hiro_voice("HiroPlayVoiceReposeRitual")
    end
end

function hiro_on_die_state()
    -- 死亡视图可能临时切到 HiroWitchDeathAppearance；复活/下回合必须强制重同步主外观。
    setdata(SELF, D_APPEAR, 0)
end

-- 用牌前按「实际发动瞬间」的魔女化状态确定技能（BeforeUse）。
-- 仪表盘上选定的技能可能在本回合较早的「魔女安息仪式」后已经过期，
-- 因此这里必须同时处理常态→魔女化与魔女化→常态两个方向。
function hiro_before_use()
    if is_corroding() then return end   -- 侵蚀中：不改写正在使用的技能（放行侵蚀EGO）
    local w = st(SELF, WZ)
    local id = current_skill_id()
    if id == RITUAL then hiro_ritual_keep_form(); return end

    if w <= 0 then
        -- 「解脱」由 DLL 的 IsActionable 补丁取消整次行动；绝不替换成常态三技能。
        -- 正常情况下该行动不会进入 BeforeUse，这里只保留防御性返回。
        if id == DELIV then
            return
        elseif id == 9750111 or id == 9750131 then
            changeskill(9750101)
        elseif id == 9750112 or id == 9750132 then
            changeskill(9750102)
        elseif id == 9750113 or id == 9750133 then
            changeskill(9750103)
        end
        return
    end

    if id == DELIV then return end   -- 仍在魔女化：允许发动解脱
    local s1, s2, s3 = 9750111, 9750112, 9750113
    if w >= 50 then s1, s2, s3 = 9750131, 9750132, 9750133 end
    if id == 9750101 or id == 9750111 or id == 9750131 then
        if id ~= s1 then changeskill(s1) end
    elseif id == 9750102 or id == 9750112 or id == 9750132 then
        if id ~= s2 then changeskill(s2) end
    elseif id == 9750103 or id == 9750113 or id == 9750133 then
        if id ~= s3 then changeskill(s3) end
    end
end

-- 拼点胜利施加反驳（每回合最多1次）；魔女化二技能额外伤害%
function hiro_rebuttal_skill()
    if data(D_REB_SKILL) == 0 then
        inflict_rebuttal(TARGET, 1)
        setdata(SELF, D_REB_SKILL, 1)
    end
    local id = current_skill_id()
    if (id == 9750112 or id == 9750132) and st(TARGET, REB) > 0 then
        dmgmult(clamp(st(TARGET, REB) * 10, 0, 30))
    end
end

-- 三技能攻击后：-10理智；若击杀/混乱目标 额外+20因子（EndSkill）
function hiro_skill3_after()
    drain_sp(10)
    local s = getunitstate(TARGET)
    if s == 0 or s == 2 then gain_factor(20) end
end

-- 硬币：目标带反驳→追加50%傲慢伤害
function hiro_pride_bonus()
    if st(TARGET, REB) > 0 then
        local dmg = getdmg()
        if dmg > 0 then bonusdmg(TARGET, math.floor(dmg * 0.5), -1, PRIDE) end
    end
end

-- 仪礼剑：施加[流血]层数/强度时 +1
function hiro_ritual_bleed_stack()
    if st(SELF, RS) > 0 then buff(TARGET, LAC, 0, 1, 0) end
end
function hiro_ritual_bleed_potency()
    if st(SELF, RS) > 0 then buff(TARGET, LAC, 1, 0, 0) end
end

-- 仪礼剑：基础技能最后一枚硬币命中时，额外触发1次[流血]，且不额外消耗[流血]次数。
-- JSON 中在 before/after 中间接一段 ForceToActivateBuffOSA；有仪礼剑时先临时+1次数供原生触发消耗，
-- 无仪礼剑时临时藏起目标流血，避免无条件原生触发脚本误触发。
function hiro_rs_bleed_gate_before()
    setdata(TARGET, D_RS_LAC_STACK_HELD, 0)
    setdata(TARGET, D_RS_LAC_TURN_HELD, 0)

    local p = st(TARGET, LAC)
    local c = ct(TARGET, LAC)
    if st(SELF, RS) > 0 then
        if p > 0 then buff(TARGET, LAC, 0, 1, 0) end
        return
    end

    if p ~= 0 or c ~= 0 then
        setdata(TARGET, D_RS_LAC_STACK_HELD, p)
        setdata(TARGET, D_RS_LAC_TURN_HELD, c)
        buff(TARGET, LAC, -p, -c, 0)
    end
end

function hiro_rs_bleed_gate_after()
    local p = unitdata(TARGET, D_RS_LAC_STACK_HELD)
    local c = unitdata(TARGET, D_RS_LAC_TURN_HELD)
    if p ~= 0 or c ~= 0 then buff(TARGET, LAC, p, c, 0) end
    setdata(TARGET, D_RS_LAC_STACK_HELD, 0)
    setdata(TARGET, D_RS_LAC_TURN_HELD, 0)
end

-- 烧伤/流血「触发」已改用 JSON 原生 ForceToActivateBuffOSA / ...ValueTimes（命中时引爆）：
-- 原版人格写法（参考 Ryoshu 1031005 流血 / 1041506 烧伤 / 解脱用 ...ValueTimes value:3），
-- 命中即结算独立伤害数字，且每触发1次自动消耗1层（次数），无需 Lua 再手动减层。
-- 详见 Hiro-Skills.json 的 9750103/9750113/9750133/9750121 各三技能 III 硬币。

------------------------------------------------------------------
-- 守备技能
------------------------------------------------------------------

-- 伪证：无回溯与回溯-魔女化时，获得最大生命50%护盾
function hiro_guard_shield()
    if st(SELF, RW) > 0 or st(SELF, RWW) > 0 then return end
    local amt = math.floor(gethp(SELF, "max") * 0.5)
    if amt > 0 then shield(SELF, amt) end
end

-- 守备：战斗开始施加3反驳（每回合最多1次）
function hiro_rebuttal_guard()
    if data(D_REB_DEF) == 0 then
        inflict_rebuttal(TARGET, 3)
        setdata(SELF, D_REB_DEF, 1)
    end
end

-- 由我来拯救：每10魔女化 基础威力+1（最多4）
function hiro_witch_guard_power()
    base(clamp(math.floor(st(SELF, WZ) / 10), 0, 4))
end

-- 由我来拯救·战斗开始：理智<-20则恢复10
function hiro_def_witch_start()
    if getsp(SELF) < -20 then heal_self_sp(10) end
end

-- 由我来拯救·闪避成功：回5理智（每回合≤3次，不超过-10）
function hiro_evade()
    local n = data(D_EVADE)
    if n >= 3 or getsp(SELF) >= -10 then return end
    heal_self_sp(clamp(-10 - getsp(SELF), 0, 5))
    setdata(SELF, D_EVADE, n + 1)
end

-- 由我来拯救·回合结束：只从「可侵蚀、当前未陷入侵蚀、除自身以外」的友方单位里，
-- 使编号(编队顺序)最靠后的一名理智值降至 -45（参考六号线第三区段「玩吗」被动的强制侵蚀）。
-- 每回合最多 1 次：守备技能的回合结束时机可能随每次拼点重复触发，靠 SELF 上的 D_DEF_SP
-- 标记在所有触发间共享，保证整回合只生效一次（即「所有同名技能合计一次」而非每次一次）。
function hiro_def_witch_endround()
    if data(D_DEF_SP) == 1 then return end                  -- 本回合已触发
    if st(SELF, WZ) == 0 or is_corroding() then return end  -- 仅守备-魔女化在身（魔女化、自身未侵蚀）
    if getunitstate(SELF) ~= 1 then return end              -- 自身需存活

    local allies = selecttargets("AllyExceptSelf99")
    if allies == nil or #allies == 0 then return end

    -- 合格 = 可侵蚀 且 当前未陷入侵蚀；在合格者里取 deployment(编号) 最大者=最靠后。
    --  · 未陷入侵蚀：理智 > -45（用户定义；已侵蚀/恐慌者理智已触底，被排除）。
    --  · 可侵蚀：getstat(u,"CanBeErodedUnit")，由本 mod 配套的只读插件 HiroCorrosionStat.dll 暴露
    --    引擎自带的 BattleUnitModel.CanBeErodedUnit()（=有理智槽 且 带可侵蚀EGO，"只带初始EGO"的判 0）。
    --    1=可侵蚀 / 0=不可 / -1=插件未加载→退回近似(有理智槽 hasMp 或 getsp~=0，无法排除只带初始EGO者)。
    local pick, best = nil, nil
    for _, u in ipairs(allies) do
        local sp = getsp(u)
        local ce = safestat(u, "CanBeErodedUnit")
        local corrodible
        if ce >= 0 then corrodible = (ce == 1)
        else corrodible = (safestat(u, "hasMp") == 1) or (sp ~= 0) end
        if sp > SP_CORROSION and corrodible then
            local order = safestat(u, "deployment")         -- 编号越大=编队越靠后（已实测 deployment 可用）
            if best == nil or order >= best then
                best, pick = order, u
            end
        end
    end
    if pick == nil then return end

    healsp(pick, SP_CORROSION - getsp(pick))                -- 设为 -45（合格条件已保证此处为下调）
    setdata(SELF, D_DEF_SP, 1)
end

------------------------------------------------------------------
-- 被动：我带着一切答案回到今天（安息获取 + 特殊技能转化）
------------------------------------------------------------------

-- 遭遇开始：重置累积安息，只同步敌方数/魔女化友方数这类当前场况。
function hiro_repose_es()
    if data(D_REPOSE_LOCK) == 1 then return end
    setdata(SELF, D_REPOSE_OWNER, 1)
    setdata(SELF, D_REPOSE_ACC, 0)
    sync_repose()
end

-- 友方监听被动：任意友方使用侵蚀EGO技能时，使带「我带着一切答案」的希罗累积1层安息。
function hiro_repose_ego_use()
    local owner = find_repose_owner()
    if owner == nil or unitdata(owner, D_REPOSE_LOCK) == 1 then return end
    local ego = (getskillegotype ~= nil) and getskillegotype(SELF) or 0
    if ego == 2 or ego == 3 or ego == 4 then add_repose_acc_to(owner, 1) end
end

-- 回合开始：①安息获取(侵蚀友方数)；②决定本回合三技能槽转化(解脱/安息仪式)。
-- 转化在 hiro_skill_phase(AfterSlots) 应用——RoundStart 早于 AfterSlots，D_WANT_* 先设后读。
-- 侵蚀回合不转化(避免卡顿)；解脱若因侵蚀延后，则下回合再给。解脱与安息仪式两条件独立、可同回合并存。
function hiro_answer_rs()
    restore_hiro_bgm()
    setdata(SELF, D_WANT_DELIV, 0)
    setdata(SELF, D_WANT_RITUAL, 0)
    setdata(SELF, D_DELIV_BGM_NEW, 0)
    setdata(SELF, D_RITUAL_BGM_NEW, 0)

    local repose_locked = data(D_REPOSE_LOCK) == 1
    if not repose_locked then
        add_repose_acc(corroding_friendly_count())
        sync_repose()
    end

    local want_deliv = data(D_DELIV_PEND) == 1 or (st(SELF, WZ) > 0 and getsp(SELF) <= SP_DELIV)
    local want_ritual = not repose_locked and st(SELF, REP) >= REPOSE_MAX

    if is_corroding() then
        if st(SELF, WZ) > 0 and getsp(SELF) <= SP_DELIV then setdata(SELF, D_DELIV_PEND, 1) end
        mark_special_bgm_grant(want_deliv, D_DELIV_BGM_HELD, D_DELIV_BGM_NEW)
        mark_special_bgm_grant(want_ritual, D_RITUAL_BGM_HELD, D_RITUAL_BGM_NEW)
        return
    end
    -- 解脱：魔女化 + SP≤-35(或上回合因侵蚀延后)
    if data(D_DELIV_PEND) == 1 then
        setdata(SELF, D_DELIV_PEND, 0)
        setdata(SELF, D_WANT_DELIV, 1)
    elseif st(SELF, WZ) > 0 and getsp(SELF) <= SP_DELIV then
        setdata(SELF, D_WANT_DELIV, 1)
    end
    -- 安息仪式：[安息]≥13(独立判定，可与解脱同回合并存→两个特殊三技能)
    if not repose_locked and st(SELF, REP) >= REPOSE_MAX then
        setdata(SELF, D_WANT_RITUAL, 1)
    end
    mark_special_bgm_grant(data(D_WANT_DELIV) == 1, D_DELIV_BGM_HELD, D_DELIV_BGM_NEW)
    mark_special_bgm_grant(data(D_WANT_RITUAL) == 1, D_RITUAL_BGM_HELD, D_RITUAL_BGM_NEW)
end

function hiro_bgm_eb()
    restore_hiro_bgm()
end

-- 安息仪式·攻击后：解除所有单位[魔女化]，自身此后无法再获得[安息]。
function hiro_ritual_after()
    setdata(SELF, D_RITUAL_BGM_HELD, 0)
    setdata(SELF, D_RITUAL_BGM_NEW, 0)
    each_unit(function(u)
        destroybuff(u, WZ, 0, 99, 1)
        destroybuff(u, RMARK, 0, 99, 1)   -- 清掉本次安息固伤用过的隐形标记
    end)
    setdata(SELF, D_REPOSE_LOCK, 1)
    -- 攻击后：若理智<0，恢复至0，并按此前与0的差值额外恢复(每相差1点+1)→最终理智=原值的相反数。
    -- (上面已解除[魔女化]，其 CantRecoverMpOverValue:0 封顶随之解除，理智可回到0以上。)
    local sp = getsp(SELF)
    if sp < 0 then heal_self_sp(-sp * 2) end
end

function hiro_ritual_restore()
    set_hiro_appearance(false, true)
    setdata(SELF, D_APPEAR, 0)
end

-- 安息固伤已改为「WhenUse 消耗魔女因子→给敌方叠隐形标记[ReposeMark]」+ 硬币上的原生
-- GiveAdditionalDmgViaEachTargetBuffStackAndMaxHpRatio（里卡多 RicardoBookRaid 同款，见 hiro_power 9750122 分支）。
-- 原生脚本自带独立伤害数字、且各目标按各自生命上限结算，不再需要 Lua bonusdmg。

-- (解脱三硬币「触发3次流血+减3层」已改由 JSON 原生 ForceToActivateBuffOSAValueTimes value:3 实现，见上方说明)
