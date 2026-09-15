--[[
    core/client/interiors_data.lua -- the curated IPL table (DESIGN §36).

    Pure data, no natives (safe to load offline in tests). The loader is
    client/interiors.lua; this file only builds the `groups` table and stores
    it as Core.InteriorsData (internal to core's client VM).

    IPL set researched 2026-09-15 from Bob74/bob74_ipl master (MIT licensed,
    Copyright (c) 2024 Bob74 -- https://github.com/Bob74/bob74_ipl), cross-checked
    against DurtyFree's gta-v-data-dumps/ipls.json. The name strings are Rockstar
    map data; the grouping, gates and loader are core's own. Per-interior styling
    (entity-set choices) is deliberately NOT here -- plugins own that through
    Core.Interiors.activateSet (DESIGN §36).

    Row shape: { id, label, default, minBuild?, dlc?, remove? = { ipl }, ipls = { ipl } }
    `minBuild` gates on GetGameBuildNumber(), `dlc` on IsDlcPresent().
]]

local groups = {
    { id = "base", label = "GTA V base map fixes (holes, rivers, tracks, billboards, Bahama Mamas shell)", default = true,
        remove = { "dt1_05_hc_end", "dt1_05_hc_req" },
        ipls = {
            "CS1_02_cf_onmission1", "CS1_02_cf_onmission2", "CS1_02_cf_onmission3", "CS1_02_cf_onmission4",
            "CS3_07_MPGates", "CanyonRvrShallow", "Carwash_with_spinners", "Coroner_Int_on",
            "FIBlobby", "FINBANK", "FruitBB", "atriumglmission",
            "bh1_47_joshhse_unburnt", "bh1_47_joshhse_unburnt_lod", "bkr_bi_hw1_13_int", "bkr_bi_id1_23_door",
            "canyonriver01", "canyonriver01_lod", "ch1_02_open", "ch3_rd2_bishopschickengraffiti",
            "coronertrash", "cs3_05_water_grp1", "cs3_05_water_grp1_lod", "cs5_04_mazebillboardgraffiti",
            "cs5_4_trains", "cs5_roads_ronoilgraffiti", "des_farmhouse", "dockcrane1",
            "dt1_05_hc_remove", "dt1_17_newbill", "dt1_21_prop_lift_on", "facelobby",
            "farm", "farm_lod", "farm_props", "farmint",
            "ferris_finale_anim", "hei_sm_16_interior_v_bahama_milo_", "hw1_02_newbill", "hw1_emissive_newbill",
            "id2_14_during1", "id2_14_during_door", "ld_rail_01_track", "ld_rail_02_track",
            "lr_cs6_08_grave_closed", "methtrailer_grp1", "pcranecont", "post_hiest_unload",
            "rc12b_default", "refit_unload", "sc1_01_newbill", "sc1_14_newbill",
            "shr_int", "sp1_10_real_interior", "sp1_10_real_interior_lod", "trv1_trail_start",
            "v_tunnel_hole",
        },
    },
    { id = "north_yankton", label = "North Yankton (prologue town, teleport-only, off by default)", default = false,
        ipls = {
            "DES_ProTree_start", "prologue01", "prologue01c", "prologue01d",
            "prologue01e", "prologue01f", "prologue01g", "prologue01h",
            "prologue01i", "prologue01j", "prologue01k", "prologue01z",
            "prologue02", "prologue03", "prologue03_grv_cov", "prologue03b",
            "prologue04", "prologue04b", "prologue05", "prologue05b",
            "prologue06", "prologue06_int", "prologue06b", "prologue_DistantLights",
            "prologue_LODLights", "prologue_m2_door", "prologue_occl", "prologuerd",
            "prologuerdb",
        },
    },
    { id = "ufo", label = "UFOs (hippie / Chiliad / Zancudo, off by default)", default = false,
        ipls = {
            "ufo", "ufo_eye", "ufo_lod",
        },
    },
    { id = "red_carpet", label = "Red carpet premiere setup (off by default)", default = false,
        ipls = {
            "redCarpet",
        },
    },
    { id = "heists", label = "Heist carrier + yacht", default = true,
        ipls = {
            "hei_carrier", "hei_carrier_int1", "hei_carrier_int2", "hei_carrier_int3",
            "hei_carrier_int4", "hei_carrier_int5", "hei_carrier_int6", "hei_carrier_lodlights",
            "hei_yacht_heist", "hei_yacht_heist_bar", "hei_yacht_heist_bar_lod", "hei_yacht_heist_bedrm",
            "hei_yacht_heist_bedrm_lod", "hei_yacht_heist_bridge", "hei_yacht_heist_bridge_lod", "hei_yacht_heist_enginrm",
            "hei_yacht_heist_enginrm_lod", "hei_yacht_heist_lod", "hei_yacht_heist_lounge", "hei_yacht_heist_lounge_lod",
            "hei_yacht_heist_slod",
        },
    },
    { id = "highlife", label = "High Life apartments", default = true,
        ipls = {
            "mpbusiness_int_placement_interior_v_mp_apt_h_01_milo_", "mpbusiness_int_placement_interior_v_mp_apt_h_01_milo__1", "mpbusiness_int_placement_interior_v_mp_apt_h_01_milo__2", "mpbusiness_int_placement_interior_v_mp_apt_h_01_milo__3",
            "mpbusiness_int_placement_interior_v_mp_apt_h_01_milo__4", "mpbusiness_int_placement_interior_v_mp_apt_h_01_milo__5",
        },
    },
    { id = "executive", label = "Executives apartments (Eclipse Towers)", default = true,
        ipls = {
            "apa_v_mp_h_01_a", "apa_v_mp_h_01_b", "apa_v_mp_h_01_c", "apa_v_mp_h_02_a",
            "apa_v_mp_h_02_b", "apa_v_mp_h_02_c", "apa_v_mp_h_03_a", "apa_v_mp_h_03_b",
            "apa_v_mp_h_03_c", "apa_v_mp_h_04_a", "apa_v_mp_h_04_b", "apa_v_mp_h_04_c",
            "apa_v_mp_h_05_a", "apa_v_mp_h_05_b", "apa_v_mp_h_05_c", "apa_v_mp_h_06_a",
            "apa_v_mp_h_06_b", "apa_v_mp_h_06_c", "apa_v_mp_h_07_a", "apa_v_mp_h_07_b",
            "apa_v_mp_h_07_c", "apa_v_mp_h_08_a", "apa_v_mp_h_08_b", "apa_v_mp_h_08_c",
        },
    },
    { id = "finance", label = "Finance & Felony offices", default = true,
        ipls = {
            "ex_dt1_02_office_01a", "ex_dt1_02_office_01b", "ex_dt1_02_office_01c", "ex_dt1_02_office_02a",
            "ex_dt1_02_office_02b", "ex_dt1_02_office_02c", "ex_dt1_02_office_03a", "ex_dt1_02_office_03b",
            "ex_dt1_02_office_03c", "ex_dt1_11_office_01a", "ex_dt1_11_office_01b", "ex_dt1_11_office_01c",
            "ex_dt1_11_office_02a", "ex_dt1_11_office_02b", "ex_dt1_11_office_02c", "ex_dt1_11_office_03a",
            "ex_dt1_11_office_03b", "ex_dt1_11_office_03c", "ex_sm_13_office_01a", "ex_sm_13_office_01b",
            "ex_sm_13_office_01c", "ex_sm_13_office_02a", "ex_sm_13_office_02b", "ex_sm_13_office_02c",
            "ex_sm_13_office_03a", "ex_sm_13_office_03b", "ex_sm_13_office_03c", "ex_sm_15_office_01a",
            "ex_sm_15_office_01b", "ex_sm_15_office_01c", "ex_sm_15_office_02a", "ex_sm_15_office_02b",
            "ex_sm_15_office_02c", "ex_sm_15_office_03a", "ex_sm_15_office_03b", "ex_sm_15_office_03c",
        },
    },
    { id = "bikers", label = "Biker clubhouses + businesses", default = true,
        ipls = {
            "bkr_biker_interior_placement_interior_0_biker_dlc_int_01_milo", "bkr_biker_interior_placement_interior_1_biker_dlc_int_02_milo", "bkr_biker_interior_placement_interior_2_biker_dlc_int_ware01_milo", "bkr_biker_interior_placement_interior_3_biker_dlc_int_ware02_milo",
            "bkr_biker_interior_placement_interior_4_biker_dlc_int_ware03_milo", "bkr_biker_interior_placement_interior_5_biker_dlc_int_ware04_milo", "bkr_biker_interior_placement_interior_6_biker_dlc_int_ware05_milo",
        },
    },
    { id = "import", label = "Import/Export CEO garages + vehicle warehouse", default = true,
        ipls = {
            "imp_dt1_02_cargarage_a", "imp_dt1_02_cargarage_b", "imp_dt1_02_cargarage_c", "imp_dt1_02_modgarage",
            "imp_dt1_11_cargarage_a", "imp_dt1_11_cargarage_b", "imp_dt1_11_cargarage_c", "imp_dt1_11_modgarage",
            "imp_impexp_interior_placement_interior_1_impexp_intwaremed_milo_", "imp_impexp_interior_placement_interior_3_impexp_int_02_milo_", "imp_sm_13_cargarage_a", "imp_sm_13_cargarage_b",
            "imp_sm_13_cargarage_c", "imp_sm_13_modgarage", "imp_sm_15_cargarage_a", "imp_sm_15_cargarage_b",
            "imp_sm_15_cargarage_c", "imp_sm_15_modgarage",
        },
    },
    { id = "gunrunning", label = "Gunrunning bunkers + yacht", default = true,
        ipls = {
            "gr_case0_bunkerclosed", "gr_case10_bunkerclosed", "gr_case11_bunkerclosed", "gr_case1_bunkerclosed",
            "gr_case2_bunkerclosed", "gr_case3_bunkerclosed", "gr_case4_bunkerclosed", "gr_case5_bunkerclosed",
            "gr_case6_bunkerclosed", "gr_case7_bunkerclosed", "gr_case9_bunkerclosed", "gr_grdlc_interior_placement_interior_1_grdlc_int_02_milo_",
            "gr_heist_yacht2", "gr_heist_yacht2_bar", "gr_heist_yacht2_bar_lod", "gr_heist_yacht2_bedrm",
            "gr_heist_yacht2_bedrm_lod", "gr_heist_yacht2_bridge", "gr_heist_yacht2_bridge_lod", "gr_heist_yacht2_enginrm",
            "gr_heist_yacht2_enginrm_lod", "gr_heist_yacht2_lod", "gr_heist_yacht2_lounge", "gr_heist_yacht2_lounge_lod",
            "gr_heist_yacht2_slod",
        },
    },
    { id = "smuggler", label = "Smuggler hangar", default = true,
        ipls = {
            "sm_smugdlc_interior_placement_interior_0_smugdlc_int_01_milo_",
        },
    },
    { id = "doomsday", label = "Doomsday facility", default = true,
        ipls = {
            "set_int_02_shell", "xm_bunkerentrance_door", "xm_hatch_01_cutscene", "xm_hatch_02_cutscene",
            "xm_hatch_03_cutscene", "xm_hatch_04_cutscene", "xm_hatch_06_cutscene", "xm_hatch_07_cutscene",
            "xm_hatch_08_cutscene", "xm_hatch_09_cutscene", "xm_hatch_10_cutscene", "xm_hatch_closed",
            "xm_hatches_terrain", "xm_hatches_terrain_lod", "xm_siloentranceclosed_x17", "xm_x17dlc_int_placement_interior_33_x17dlc_int_02_milo_",
        },
    },
    { id = "afterhours", label = "After Hours nightclub shell", default = true,
        ipls = {
            "ba_int_placement_ba_interior_0_dlc_int_01_ba_milo_",
        },
    },
    { id = "casino", label = "Diamond Casino doors/shell + penthouse shell (needs b2060+)", default = true,
        minBuild = 2060,
        ipls = {
            "Set_Pent_Tint_Shell", "hei_dlc_casino_aircon", "hei_dlc_casino_door", "hei_dlc_windows_casino",
            "vw_casino_carpark", "vw_casino_garage", "vw_casino_main", "vw_casino_penthouse",
            "vw_dlc_casino_door",
        },
    },
    { id = "cayoperico", label = "Cayo Perico extras (needs b2189+)", default = true,
        minBuild = 2189,
        ipls = {
            "h4_ch2_mansion_final", "h4_clubposter_keinemusik", "h4_clubposter_moodymann", "h4_clubposter_palmstraxx",
        },
    },
    { id = "tuner", label = "LS Tuners shops + meetup (needs b2372+)", default = true,
        minBuild = 2372,
        ipls = {
            "tr_tuner_meetup", "tr_tuner_race_line", "tr_tuner_shop_burton", "tr_tuner_shop_mesa",
            "tr_tuner_shop_mission", "tr_tuner_shop_rancho", "tr_tuner_shop_strawberry",
        },
    },
    { id = "security", label = "The Contract: fixer offices, garage, studio shell, billboards (needs b2545+)", default = true,
        minBuild = 2545,
        ipls = {
            "sf_billboards", "sf_fixeroffice_bh1_05", "sf_fixeroffice_hw1_08", "sf_fixeroffice_kt1_05",
            "sf_fixeroffice_kt1_08", "sf_int_placement_sec_interior_2_dlc_garage_sec_milo_", "sf_musicrooftop",
        },
    },
    { id = "criminal_enterprise", label = "Criminal Enterprise warehouses + Simeon fix (needs b2699+)", default = true,
        minBuild = 2699,
        ipls = {
            "reh_int_placement_sum2_interior_0_dlc_int_03_sum2_milo_", "reh_int_placement_sum2_interior_1_dlc_int_04_sum2_milo_", "reh_simeonfix",
        },
    },
    { id = "drugwars", label = "Drug Wars fixes, freakshop, garage, train crash (needs b2802+)", default = true,
        minBuild = 2802,
        ipls = {
            "xm3_collision_fixes", "xm3_garage_fix", "xm3_security_fix", "xm3_sum2_fix",
            "xm3_train_crash", "xm3_warehouse", "xm3_warehouse_grnd",
        },
    },
    { id = "mercenaries", label = "Mercenaries map fixes (needs b2944+)", default = true,
        minBuild = 2944,
        ipls = {
            "m23_1_legacy_fixes",
        },
    },
    { id = "chopshop", label = "Chop Shop fixes, cargoship, lifeguard, salvage (needs b3095+)", default = true,
        minBuild = 3095,
        ipls = {
            "m23_2_acp_collision_fixes_01", "m23_2_acp_collision_fixes_02", "m23_2_cargoship", "m23_2_cargoship_bridge",
            "m23_2_cs1_05_reds", "m23_2_cs4_11_reds", "m23_2_hei_yacht_collision_fixes", "m23_2_id2_04_reds",
            "m23_2_lifeguard_access", "m23_2_sc1_03_reds", "m23_2_sp1_03_reds", "m23_2_tug_collision",
            "m23_2_vinewood_garage",
        },
    },
    { id = "bounties", label = "Bottom Dollar Bounties carrier + offices (needs b3258+)", default = true,
        minBuild = 3258,
        ipls = {
            "m24_1_bailoffice_davis", "m24_1_bailoffice_delperro", "m24_1_bailoffice_missionrow", "m24_1_bailoffice_paletobay",
            "m24_1_bailoffice_vinewood", "m24_1_carrier", "m24_1_carrier_int1", "m24_1_carrier_int2",
            "m24_1_carrier_int3", "m24_1_carrier_int4", "m24_1_carrier_int5", "m24_1_carrier_int6",
            "m24_1_carrier_ladders", "m24_1_legacyfixes", "m24_1_pizzasigns",
        },
    },
    { id = "agents", label = "Agents of Sabotage fixes, airstrip, factory, hangar door (needs b3407+)", default = true,
        minBuild = 3407,
        ipls = {
            "m24_2_airstrip", "m24_2_garment_factory", "m24_2_legacy_fixes", "m24_2_mp2024_02_additions",
            "m24_2_prop_m42_hangerdoor_02a",
        },
    },
    { id = "money_fronts", label = "Money Fronts carwash + smoke-on-water/helitours (needs mp2025_01)", default = true,
        dlc = "mp2025_01",
        ipls = {
            "m25_1_bobcat", "m25_1_carwash", "m25_1_ch2_04_construction", "m25_1_cs1_06e_construction",
            "m25_1_garage", "m25_1_helitours", "m25_1_legacy_fixes", "m25_1_mp2025_01_additions",
            "m25_1_quikpharma", "m25_1_smokeonthewater",
        },
    },
    { id = "mansions", label = "Safehouse-in-the-Hills mansions (needs mp2025_02)", default = true,
        dlc = "mp2025_02",
        ipls = {
            "apa_ch2_04_mansion_firepit", "apa_ch2_04_mansion_furniture", "apa_ch2_04_mansion_private", "apa_ch2_04_mansion_railings_p",
            "apa_ch2_04_mansion_shared", "apa_ch2_04_mansion_shared_distantlights", "apa_ch2_04_mansion_shared_lodlights", "hei_ch1_06e_mansion_firepit",
            "hei_ch1_06e_mansion_furniture", "hei_ch1_06e_mansion_private", "hei_ch1_06e_mansion_railings_p", "hei_ch1_06e_mansion_shared",
            "hei_ch1_06e_mansion_shared_distantlights", "hei_ch1_06e_mansion_shared_lodlights", "hei_ch1_06f_mansion_shared", "hei_ch1_09_mansion_firepit",
            "hei_ch1_09_mansion_furniture", "hei_ch1_09_mansion_private", "hei_ch1_09_mansion_railings_p", "hei_ch1_09_mansion_shared",
            "hei_ch1_09_mansion_shared_distantlights", "hei_ch1_09_mansion_shared_lodlights", "hei_ch1_roads_mansion", "m25_2_ch1_06e_mansion_interior_a",
            "m25_2_ch1_06e_mansion_interior_b", "m25_2_ch1_06e_mansion_interior_c", "m25_2_ch1_09_mansion_interior_a", "m25_2_ch1_09_mansion_interior_b",
            "m25_2_ch1_09_mansion_interior_c", "m25_2_ch2_04_mansion_interior_a", "m25_2_ch2_04_mansion_interior_b", "m25_2_ch2_04_mansion_interior_c",
            "m25_2_dog_house", "m25_2_east_dog_house", "m25_2_east_mansion_gym", "m25_2_knoway_sign",
            "m25_2_mansion_gym", "m25_2_mansion_props", "m25_2_tongva_dog_house", "m25_2_tongva_mansion_gym",
        },
    },
    { id = "kortz", label = "Kortz Center additions (needs mp2026_01)", default = true,
        dlc = "mp2026_01",
        ipls = {
            "m26_1_mp2026_01_additions_critical_0", "m26_1_mp2026_01_additions_exterior", "m26_1_mp2026_01_additions_exterior_cctv",
        },
    },
}

-- 369 IPLs

-- Internal to core's client VM; interiors.lua reads it at boot.
Core.InteriorsData = groups
