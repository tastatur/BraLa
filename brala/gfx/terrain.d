module brala.gfx.terrain;

private {
    import stb_image : stbi_load_from_memory, stbi_image_free;
    import gl3n.math : sign;
    import glamour.sampler : Sampler;
    import glamour.gl;
    
    import std.path : expandTilde, baseName, extension, stripExtension, setExtension;
    import std.algorithm : canFind, min, max, countUntil;
    import std.string : format, splitLines, strip;
    import std.array : split, replace;
    import std.exception : enforceEx;
    import std.conv : to;
    import file = std.file;
    
    import brala.log : logger = terrain_logger;
    import brala.engine : BraLaEngine;
    import brala.resmgr : ResourceManager;
    import brala.utils.log;
    import brala.utils.atlas : Atlas, Rectangle;
    import brala.utils.image : Image, RGB, RGBA;
    import brala.utils.exception : ImageException, AtlasException;
    import brala.utils.zip : ZipArchive, ArchiveMember;
}



struct AtlasImage {
    Image image;
    alias image this;

    AnimatedImage[] images;

    size_t position;
    int frame;

    Image get_next() {
        return image;
    }
}

struct AnimatedImage {
    Image image;
    alias image this;

    int duration;
}

bool is_power_of_two(Image image) {
    if(image.width == 0 || image.height == 0 ||
        (image.width & (image.width - 1)) ||
        (image.height & (image.height - 1))) {

        return false;
    }

    return true;
}

struct TextureCoordinate {
    short x;
    short y;

    short half_width;
    short half_height;

    // the *full* texture without rotation
    short[2][4] def;

    this(Rectangle rect) {
        assert((rect.x + rect.width / 2) <= short.max);
        assert((rect.y + rect.height / 2) <= short.max);
        half_width = cast(short)(rect.width / 2);
        half_height = cast(short)(rect.height / 2);
        x = cast(short)(rect.x + half_width);
        y = cast(short)(rect.y + half_height);

        def = [
            [cast(short)(rect.x), cast(short)(rect.y+rect.height)],
            [cast(short)(rect.x+rect.width), cast(short)(rect.y+rect.height)],
            [cast(short)(rect.x+rect.width), cast(short)(rect.y)],
            [cast(short)(rect.x), cast(short)(rect.y)]
        ];
    }

    @safe nothrow const pure
    short[2][4] r0() {
        return def;
    }

    @safe nothrow const pure
    short[2][4] r90() {
        return [[cast(short)(x+half_width), cast(short)(y+half_height)],
                [cast(short)(x+half_width), cast(short)(y-half_height)],
                [cast(short)(x-half_width), cast(short)(y-half_height)],
                [cast(short)(x-half_width), cast(short)(y+half_height)]];
    }

    @safe nothrow const pure
    short[2][4] r180() {
        return [[cast(short)(x+half_width), cast(short)(y-half_height)],
                [cast(short)(x-half_width), cast(short)(y-half_height)],
                [cast(short)(x-half_width), cast(short)(y+half_height)],
                [cast(short)(x+half_width), cast(short)(y+half_height)]];
    }

    @safe nothrow const pure
    short[2][4] r270() {
        return [[cast(short)(x-half_width), cast(short)(y-half_height)],
                [cast(short)(x-half_width), cast(short)(y+half_height)],
                [cast(short)(x+half_width), cast(short)(y+half_height)],
                [cast(short)(x+half_width), cast(short)(y-half_height)]];
    }

    @safe nothrow const pure
    short[2][4] r0(short left, short right, short top, short bottom) {
        return [[cast(short)(x-left), cast(short)(y+bottom)],
                [cast(short)(x+right), cast(short)(y+bottom)],
                [cast(short)(x+right), cast(short)(y-top)],
                [cast(short)(x-left), cast(short)(y-top)]];
    }

    @safe nothrow const pure
    short[2][4] r90(short left, short right, short top, short bottom) {
        return [[cast(short)(x+right), cast(short)(y+bottom)],
                [cast(short)(x+right), cast(short)(y-top)],
                [cast(short)(x-left), cast(short)(y-top)],
                [cast(short)(x-left), cast(short)(y+bottom)]];
    }

    @safe nothrow const pure
    short[2][4] r180(short left, short right, short top, short bottom) {
        return [[cast(short)(x+right), cast(short)(y-top)],
                [cast(short)(x-left), cast(short)(y-top)],
                [cast(short)(x-left), cast(short)(y+bottom)],
                [cast(short)(x+right), cast(short)(y+bottom)]];
    }

    @safe nothrow const pure
    short[2][4] r270(short left, short right, short top, short bottom) {
        return [[cast(short)(x-left), cast(short)(y-top)],
                [cast(short)(x-left), cast(short)(y+bottom)],
                [cast(short)(x+right), cast(short)(y+bottom)],
                [cast(short)(x+right), cast(short)(y-top)]];
    }
}

struct CubeSideData {
    float[3][4] positions;
    float[3] normal;
}

struct ProjectionTextureCoordinates {
    short x;
    short y;

    short x2; // texture for normal +y
    short y2;

    short x3; // texture for normal -y
    short y3;

    short width;
    short height;

    @safe nothrow const pure
    short[2][4] project_on_cbsd(CubeSideData cbsd) {
        // an normale erkennbar welche koordinate fix ist
        // die koodinaten zu UVs umformen? cast(short)(foo*2)?

        short x = this.x;
        short y = this.y;

        size_t index_1;
        size_t index_2;

        // n is the counterpart to s, it allows to midify the x coordinates
        float n = 1.0f;
        // used to flip the signs if normal doesn't point toward +y
        // since in OpenGL +y goes up but in the texture atlas +y goes down
        float s = 1.0f;

        if(cbsd.normal[1] == 0.0f && cbsd.normal[2] == 0.0f) {
            // x
            index_1 = 2;
            index_2 = 1;
            s = -1.0f; // flip here

            //n = sign(cbsd.normal[0]);
            n = sign(-cbsd.normal[0]);
        } else if(cbsd.normal[0] == 0.0f && cbsd.normal[2] == 0.0f) {
            // y
            index_1 = 0;
            index_2 = 2;
            n = sign(cbsd.normal[1]);

            if(n > 0) { // y+
                x = x2;
                y = y2;
            } else if(n < 0) { // y-
                x = x3;
                y = y3;
            }
        } else if(cbsd.normal[0] == 0.0f && cbsd.normal[1] == 0.0f) {
            // z
            index_1 = 0;
            index_2 = 1;
            s = -1.0f; // flip here
            n = sign(cbsd.normal[2]);
        } else {
            assert(false, "normal not supported");
        }

        short[2][4] ret;

        foreach(i, ref vertex; cbsd.positions) {
            ret[i][0] = cast(short)(x + vertex[index_1]*width*n);
            ret[i][1] = cast(short)(y + vertex[index_2]*height*s);
        }

        return ret;
    }
}


// open("/tmp/l", 'w').write(str([p.rsplit('.', 1)[0] for p in sorted(os.listdir("/tmp/mmm/textures/blocks/"))]).replace("'", '"'))
enum string[] ORDER = ["activatorRail", "activatorRail_powered",
                       "anvil_base", "anvil_top", "anvil_top_damaged_1", "anvil_top_damaged_2", "beacon",
                       "bed_feet_end", "bed_feet_side", "bed_feet_top", "bed_head_end", "bed_head_side", "bed_head_top",
                       "bedrock", "blockDiamond", "blockEmerald", "blockGold", "blockIron", "blockLapis", "blockRedstone",
                       "bookshelf", "brewingStand", "brewingStand_base", "brick", "cactus_bottom", "cactus_side", "cactus_top",
                       "cake_bottom", "cake_inner", "cake_side", "cake_top", "carrots_0", "carrots_1", "carrots_2", "carrots_3",
                       "cauldron_bottom", "cauldron_inner", "cauldron_side", "cauldron_top", "clay",
                       "cloth_0", "cloth_1", "cloth_2", "cloth_3", "cloth_4", "cloth_5", "cloth_6", "cloth_7", "cloth_8", "cloth_9",
                       "cloth_10", "cloth_11", "cloth_12", "cloth_13", "cloth_14", "cloth_15",
                       "cocoa_0", "cocoa_1", "cocoa_2", "commandBlock", "comparator", "comparator_lit",
                       "crops_0", "crops_1", "crops_2", "crops_3", "crops_4", "crops_5", "crops_6", "crops_7",
                       "daylightDetector_side", "daylightDetector_top", "deadbush", "destroy_0", "destroy_1", "destroy_2", "destroy_3",
                       "destroy_4", "destroy_5", "destroy_6", "destroy_7", "destroy_8", "destroy_9", "detectorRail", "detectorRail_on",
                       "dirt", "dispenser_front", "dispenser_front_vertical", "doorIron_lower", "doorIron_upper",
                       "doorWood_lower", "doorWood_upper", "dragonEgg", "dropper_front", "dropper_front_vertical",
                       "enchantment_bottom", "enchantment_side", "enchantment_top", "endframe_eye", "endframe_side", "endframe_top",
                       "farmland_dry", "farmland_wet", "fenceIron", "fern", "fire_0", "fire_0", "fire_1", "fire_1", "flower", "flowerPot",
                       "furnace_front", "furnace_front_lit", "furnace_side", "furnace_top", "glass", "goldenRail", "goldenRail_powered",
                       "grass_side", "grass_side_overlay", "grass_top", "gravel", "hellrock", "hellsand", "hopper", "hopper_inside",
                       "hopper_top", "ice", "itemframe_back", "jukebox_top", "ladder", "lava", "lava", "lava_flow", "lava_flow", "leaves",
                       "leaves_jungle", "leaves_jungle_opaque", "leaves_opaque", "leaves_spruce", "leaves_spruce_opaque", "lever",
                       "lightgem", "melon_side", "melon_top", "mobSpawner", "mushroom_brown", "mushroom_inside", "mushroom_red",
                       "mushroom_skin_brown", "mushroom_skin_red", "mushroom_skin_stem", "musicBlock", "mycel_side", "mycel_top",
                       "netherBrick", "netherStalk_0", "netherStalk_1", "netherStalk_2", "netherquartz", "obsidian", "oreCoal",
                       "oreDiamond", "oreEmerald", "oreGold", "oreIron", "oreLapis", "oreRedstone", "piston_bottom", "piston_inner_top",
                       "piston_side", "piston_top", "piston_top_sticky", "portal", "portal", "potatoes_0", "potatoes_1", "potatoes_2",
                       "potatoes_3", "pumpkin_face", "pumpkin_jack", "pumpkin_side", "pumpkin_top", "quartzblock_bottom",
                       "quartzblock_chiseled", "quartzblock_chiseled_top", "quartzblock_lines", "quartzblock_lines_top",
                       "quartzblock_side", "quartzblock_top", "rail", "rail_turn", "redstoneDust_cross", "redstoneDust_cross_overlay",
                       "redstoneDust_line", "redstoneDust_line_overlay", "redstoneLight", "redstoneLight_lit", "redtorch",
                       "redtorch_lit", "reeds", "repeater", "repeater_lit", "rose", "sand", "sandstone_bottom", "sandstone_carved",
                       "sandstone_side", "sandstone_smooth", "sandstone_top", "sapling", "sapling_birch", "sapling_jungle",
                       "sapling_spruce", "snow", "snow_side", "sponge", "stem_bent", "stem_straight", "stone", "stoneMoss",
                       "stonebrick", "stonebricksmooth", "stonebricksmooth_carved", "stonebricksmooth_cracked", "stonebricksmooth_mossy",
                       "stoneslab_side", "stoneslab_top", "tallgrass", "thinglass_top", "tnt_bottom", "tnt_side", "tnt_top", "torch",
                       "trapdoor", "tree_birch", "tree_jungle", "tree_side", "tree_spruce", "tree_top", "tripWire", "tripWireSource",
                       "vine", "water", "water", "water_flow", "water_flow", "waterlily", "web", "whiteStone", "wood", "wood_birch",
                       "wood_jungle", "wood_spruce", "workbench_front", "workbench_side", "workbench_top"];

class MinecraftAtlas : Atlas {
    TextureCoordinate[ORDER.length] texture_coordinates;
    BraLaEngine engine;
    Sampler sampler;

    this(BraLaEngine engine) {
        super(256, 256);

        this.engine = engine;

        sampler = new Sampler();
        sampler.set_parameter(GL_TEXTURE_WRAP_S, GL_REPEAT);
        sampler.set_parameter(GL_TEXTURE_WRAP_T, GL_REPEAT);
        sampler.set_parameter(GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        sampler.set_parameter(GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_LINEAR);
    }

    this(BraLaEngine engine, string path) {
        this(engine);

        load(path);
    }

    override
    void resize(int width, int height) {
        logger.log!Info("Resizing atlas from %dx%d to %dx%d", atlas.width, atlas.height, width, height);
        super.resize(width, height);
    }

    void load(string path) {
        logger.log!Info("Opening texturepack: %s", path);
        ZipArchive za = new ZipArchive(path);

        string[] files = za.list_dir("textures/blocks", false);
        logger.log!Info("Processing ~%d textures", files.length);
        foreach(f; files) {
            string name = f.baseName();

            if(f.extension() == ".png") {
                auto am = za.directory[f];
                Image image = Image.from_memory(za.expand(am));

                if(image.comp != RGBA) {
                    image = image.convert(RGBA);
                }

                AtlasImage atlas_image;
                atlas_image.image = image;

                string anim_file = f.setExtension(".txt");
                if(files.canFind(anim_file)) {
                    am = za.directory[anim_file];
                    auto data = cast(char[])za.expand(am);

                    foreach(line; data.splitLines()) {
                        foreach(comma; line.split(",")) {
                            auto anim_data = comma.replace(" ", "").split("*");
                            if(anim_data.length == 0) {
                                continue;
                            } else if(anim_data.length > 2) {
                                throw new AtlasException("Malformed animation file: " ~ anim_file);
                            }

                            AnimatedImage anim_image;

                            int index = to!int(anim_data[0]);
                            if(index < 0) {
                                throw new AtlasException("Negative animation frame: " ~ anim_file);
                            }

                            int min_ = min(image.width, image.height);
                            int max_ = max(image.width, image.height);
                            if((index+1)*min_ > max_) {
                                throw new AtlasException("Animation frame %s does not exist in %s".format(index, f));
                            }

                            if(image.width > image.height) {
                                anim_image.image = image.crop(index*image.height, 0, (index+1)*image.height, image.height);
                            } else {
                                anim_image.image = image.crop(0, index*image.width, image.width, (index+1)*image.width);
                            }

                            assert(anim_image.image.width == min(image.width, image.height));
                            assert(anim_image.image.width == anim_image.image.height);

                            if(anim_data.length == 2) {
                                int duration = to!int(anim_data[1]);

                                if(duration < 0) {
                                    throw new AtlasException("Negative animation duration: " ~ anim_file);
                                }
                                anim_image.duration = duration;
                            }

                            enforceEx!AtlasException(anim_image.is_power_of_two(),
                                                     "Animationframe %s is not a power of two: %s".format(index, f));

                            atlas_image.images ~= anim_image;
                        }
                    }

                    if(atlas_image.images.length) {
                        insert(atlas_image.images[0], name.stripExtension());
                    }

                    continue;
                }

                enforceEx!AtlasException(atlas_image.is_power_of_two(), "Image sides are not a power of two: " ~ f);
                insert(atlas_image.image, name.stripExtension());
            }
        }

        logger.log!Info("All files processed");

        update_texture_coordinates();

        engine.set_texture("terrain", texture, sampler);
    }

    protected void update_texture_coordinates() {
        logger.log!Info("Updating texture coordinates...");

        foreach(name; map.keys()) {
            long index = ORDER.countUntil(name);
            if(index < 0) {
                logger.log!Info("Found unexpected texture %s", name);
            }

            texture_coordinates[index] = TextureCoordinate(map[name].area);
        }

        logger.log!Info("Done");
    }

    short[2][4] get(string s, int rotation = 0)() if(rotatation == 0 || rotatation == 90 ||
                                                     rotatation == 180 || rotation == 270) {
        enum index = ORDER.countUntil(s);
        static assert(index >= 0, "No valid texture name");

        static if(rotation == 0) {
            return texture_coordinates[index].def;
        } else static if(rotation == 90) {
            return texture_coordinates[index].r90();
        } else static if(rotation == 180) {
            return texture_coordinates[index].r180();
        } else static if(rotation == 270) {
            return texture_coordinates[index].r270();
        }
    }

    short[2][4] get(string s, int rotation, short left, short right, short top, short bottom)()
        if(rotatation == 0 || rotatation == 90 || rotatation == 180 || rotation == 270) {

        enum index = ORDER.countUntil(s);
        static assert(index >= 0, "No valid texture name");

        enum leftc = 16/left;
        enum rightc = 16/right;
        enum topc = 16/top;
        enum bottomc = 16/bottom;

        auto tex = texture_coordinates[index];

        static if(rotation == 0) {
            return texture_coordinates[index].r0(leftc*tex.half_width, rightc*tex.half_width,
                                                 topc*tex.half_height, bottomc*tex.half_height);
        } else static if(rotation == 90) {
            return texture_coordinates[index].r90(leftc*tex.half_width, rightc*tex.half_width,
                                                  topc*tex.half_height, bottomc*tex.half_height);
        } else static if(rotation == 180) {
            return texture_coordinates[index].r180(leftc*tex.half_width, rightc*tex.half_width,
                                                   topc*tex.half_height, bottomc*tex.half_height);
        } else static if(rotation == 270) {
            return texture_coordinates[index].r270(leftc*tex.half_width, rightc*tex.half_width,
                                                   topc*tex.half_height, bottomc*tex.half_height);
        }
    }

    ProjectionTextureCoordinates get_proj(string s1, string s2="", string s3="")() {
        static if(s3.length == 0) {
            s3 = s1;
        }

        enum index1 = ORDER.countUntil(s1);
        enum index2 = ORDER.countUntil(s2);
        enum index3 = ORDER.countUntil(s3);
        TextureCoordinate tex1 = texture_coordinates[index1];

        static if(s2.length == 0) {
            TextureCoordinate tex2 = tex1;
        } else {
            TextureCoordinate tex2 = texture_coordinates[index2];
        }

        static if(s3.length == 0) {
            TextureCoordinate tex3 = tex1;
        } else {
            TextureCoordinate tex3 = texture_coordinates[index3];
        }

        return ProjectionTextureCoordinates(tex1.x, tex1.y, tex2.x, tex2.y, tex3.x, tex3.y);
    }
}


Image extract_minecraft_terrain(string path) {
    ZipArchive za = new ZipArchive(file.read(path));

    auto am = za.directory["terrain.png"];
    auto content = za.expand(am);

    int x;
    int y;
    int comp;    
    ubyte* data = stbi_load_from_memory(content.ptr, cast(uint)content.length, &x, &y, &comp, 0);

    if(data is null) {
        throw new ImageException("Unable to load terrain.png");
    }

    scope(exit) stbi_image_free(data);

    if(!(comp == RGB || comp == RGBA)) {
        throw new ImageException("Unknown/Unsupported stbi image format");
    }

    return new Image(data[0..x*y*comp].dup, x, y, comp);
}
