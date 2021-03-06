module brala.dine.world;

private {
    import glamour.gl;
    import glamour.vbo : Buffer;
    import glamour.vao : VAO;
    import glamour.shader : Shader;
    
    import gl3n.linalg;
    import gl3n.aabb : AABB;

    import std.typecons : Tuple;
    import core.time : msecs;

    import brala.log : logger = world_logger;
    import brala.utils.log;
    import brala.dine.chunk : Chunk, Block;
    import brala.dine.builder.biomes : BiomeSet;
    import brala.dine.builder.tessellator : Tessellator;
    import brala.dine.util : py_div, py_mod;
    import brala.gfx.data : Vertex;
    import brala.gfx.terrain : MinecraftAtlas;
    import brala.exception : WorldError;
    import brala.resmgr : ResourceManager;
    import brala.engine : BraLaEngine;
    import brala.utils.gloom : Gloom;
    import brala.utils.ringbuffer : RingBuffer;
    import brala.utils.thread : Thread, VerboseThread, Event, thread_isMainThread;
    import brala.utils.memory : MemoryCounter, malloc, realloc, free;
}

private enum Block AIR_BLOCK = Block(0);

struct Pointer {
    void* ptr = null;
    alias ptr this;
    size_t length = 0;

    this(size_t size) {
        ptr = cast(void*)malloc(size);
        length = size;
    }

    void realloc(size_t size) {
        ptr = cast(void*).realloc(ptr, size);
        length = size;
    }

    void realloc_interval(ptrdiff_t interval) {
        realloc(length + interval);
    }

    void realloc_interval_if_needed(size_t stored, ptrdiff_t interval) {
        if(stored+interval >= length) {
            realloc_interval(interval);
        }
    }

    void free() {
        .free(ptr);
        ptr = null;
        length = 0;
    }
}

struct TessellationBuffer {
    Pointer terrain;
    Pointer light;

    private Event _event;
    @property event() {
        if(_event is null) {
            _event = new Event();
            available = true;
        }

        return _event;
    }

    @property bool available() {
        return !event.is_set();
    }

    @property void available(bool yn) {
        if(yn) {
            event.set();
        } else {
            event.clear();
        }
    }

    void wait_available() {
        event.wait();
    }

    this(size_t size, size_t light_size) {
        terrain = Pointer(size);
        light = Pointer(light_size);
    }

    void free() {
        terrain.free();
        light.free();
    }
}

alias Tuple!(Chunk, "chunk", TessellationBuffer*, "buffer", size_t, "elements") TessOut;
alias Tuple!(Chunk, "chunk", vec3i, "position") ChunkData;

final class World {
    // approximations / educated guesses
    static const default_tessellation_buffer_size = width*height*depth*Vertex.sizeof*6;
    static const default_light_buffer_size = 12*4*500;
    
    static const int width = 16;
    static const int height = 256;
    static const int depth = 16;
    static const int ystep = width*depth;
    static const int min_height = 0;
    static const int max_height = height;

    Chunk[vec3i] chunks;
    vec3i spawn;

    protected BraLaEngine engine;
    BiomeSet biome_set;
    MinecraftAtlas atlas;

    // NOTE: don't join on these queues!
    protected RingBuffer!ChunkData input;
    protected TessellationThread tessellation_thread;
    
    this(BraLaEngine engine, MinecraftAtlas atlas) {
        this.engine = engine;
        this.atlas = atlas;
        biome_set.update_colors(engine.resmgr);

        assert(engine.resmgr.get!Gloom("sphere").stride == 3, "invalid sphere");

        engine.on_shutdown.connect!"shutdown"(this);

        // Renderdistance 10 has a maximum of 441 chunks
        // Renderdistance 15 has a maximum of 961 chunks
        // Better safe than sorry!
        // Also add this memory to the GC range, TessOut
        // contains a GC allocated class (Chunk).
        // TODO check if GC is needed!
        input = new RingBuffer!ChunkData(1024, true);

        tessellation_thread = new TessellationThread(this, input);
        tessellation_thread.name = "BraLa Tessellation Thread";
        tessellation_thread.start();
    }
    
    this(BraLaEngine engine, MinecraftAtlas atlas, vec3i spawn) {
        this(engine, atlas);
        this.spawn = spawn;
    }

    @property
    bool is_ok() {
        return tessellation_thread.isRunning;
    }
   
    // when a chunk is passed to this method, the world will take care of it's memory
    // you should also lose all other references to this chunk
    //
    // old chunk will be cleared
    void add_chunk(Chunk chunk, vec3i chunkc, bool mark_dirty=true)
        in { assert(chunk !is null, "chunk was null"); }
        body {
            if(Chunk* c = chunkc in chunks) {
                remove_chunk(chunkc, *c, false);
            }

            vec3i w_chunkc = vec3i(chunkc.x*width, chunkc.y*height, chunkc.z*depth);
            AABB aabb = AABB(vec3(w_chunkc), vec3(w_chunkc.x+width, w_chunkc.y+height, w_chunkc.z+depth));
            chunk.aabb = aabb;

            chunks[chunkc] = chunk;
            if(mark_dirty) {
                mark_surrounding_chunks_dirty(chunkc);
            }
        }

    /// only safe when called from mainthread
    void remove_chunk(vec3i chunkc, bool mark_dirty=true)
        in { assert(chunkc in chunks, "Chunkc not in chunks: %s".format(chunkc)); }
        body {
            remove_chunk(chunkc, chunks[chunkc], mark_dirty);
        }

    void remove_chunk(vec3i chunkc, Chunk chunk, bool mark_dirty=true)
        in { assert(chunk !is null, "chunk was null"); }
        body {
            chunk.shutdown();
            chunks.remove(chunkc);

            if(mark_dirty) {
                mark_surrounding_chunks_dirty(chunkc);
            }
        }

    void remove_all_chunks() {
        foreach(key; chunks.keys()) {
            remove_chunk(key, false);
        }
    }

    void shutdown() {
        logger.log!Info("Disconnecting world from shutdown event");
        engine.on_shutdown.disconnect!"shutdown"(this);

        logger.log!Info("Sending stop to tessellation thread");
        tessellation_thread.stop();

        // threads wait on the buffer until it gets available,
        // so tell them the buffer is free, so they actually reach
        // the stop code, otherwise we'll wait for ever!        
        logger.log!Info("Marking buffer as available");
        if(auto tess_out = tessellation_thread.get()) {
            tess_out.buffer.available = true;
        }

        if(tessellation_thread.isRunning) {
            logger.log!Info(`Waiting on thread: "%s"`, tessellation_thread.name);
            tessellation_thread.join(false);
        } else {
            logger.log!Info(`Thread "%s" already terminated`, tessellation_thread.name);
        }
        tessellation_thread.free();

        logger.log!Info("Removing all chunks (%s)", chunks.length);
        remove_all_chunks();
    }
    
    Chunk get_chunk(int x, int y, int z) {
        return get_chunk(vec3i(x, y, z));
    }
    
    Chunk get_chunk(vec3i chunkc) {
        if(Chunk* c = chunkc in chunks) {
            return *c;
        }
        return null;
    }

    void set_block(vec3i position, Block block)
        in { assert(position.y >= min_height && position.y <= max_height, "Invalid height"); }
        body {
            vec3i chunkc = vec3i(py_div(position.x, width),
                                 py_div(position.y, height),
                                 py_div(position.z, depth));
            Chunk chunk = get_chunk(chunkc);
            
            if(chunk is null) {
                throw new WorldError("No chunk available for position " ~ position.toString());
            }
            
            uint flat = chunk.to_flat(py_mod(position.x, width),
                                      py_mod(position.y, height),
                                      py_mod(position.z, depth));
            
            if(chunk[flat] != block) {
                chunk[flat] = block;
                mark_surrounding_chunks_dirty(chunkc);
            }
        }
    
    Block get_block(vec3i position)
        in { assert(position.y >= min_height && position.y <= max_height, "Invalid height"); }
        body {
            Chunk chunk = get_chunk(py_div(position.x, width),
                                    py_div(position.y, height),
                                    py_div(position.z, depth));
            
            if(chunk is null) {
                throw new WorldError("No chunk available for position " ~ position.toString());
            }
            
            return chunk.blocks[chunk.to_flat(py_mod(position.x, width),
                                              py_mod(position.y, height),
                                              py_mod(position.z, depth))];
        }

    Block get_block_safe(vec3i position, Block def = AIR_BLOCK) {
        return get_block_safe(position.x, position.y, position.z, def);
    }

    Block get_block_safe(int wx, int wy, int wz, Block def = AIR_BLOCK) {
        Chunk chunk = get_chunk(py_div(wx, width),
                                py_div(wy, height),
                                py_div(wz, depth));

        if(chunk is null || chunk.empty) { return def; }

        int x = py_mod(wx, width);
        int y = py_mod(wy, height);
        int z = py_mod(wz, depth);
        
        if(x >= 0 && x < Chunk.width && y >= 0 && y < Chunk.height && z >= 0 && z < Chunk.depth) {
            return chunk.blocks[chunk.to_flat(x, y, z)];
        } else {
            return def;
        }
    }

    Block get_block_safe(Chunk chunk, vec3i chunkpos, vec3i position, Block def = AIR_BLOCK) {
        return get_block_safe(chunk, chunkpos.x, chunkpos.y, chunkpos.z, position.x, position.y, position.z, def);
    }

    Block get_block_safe(Chunk chunk, int x, int y, int z, int wx, int wy, int wz, Block def = AIR_BLOCK) {
        if(chunk !is null && !chunk.empty && x >= 0 && x < Chunk.width && y >= 0 && y < Chunk.height && z >= 0 && z < Chunk.depth) {
            return chunk.blocks[chunk.to_flat(x, y, z)];
        }

        return get_block_safe(wx, wy, wz);
    }

    void mark_surrounding_chunks_dirty(int x, int y, int z) {
        return mark_surrounding_chunks_dirty(vec3i(x, y, z));
    }
    
    void mark_surrounding_chunks_dirty(vec3i chunkc) {
        mark_chunk_dirty(chunkc.x+1, chunkc.y, chunkc.z);
        mark_chunk_dirty(chunkc.x-1, chunkc.y, chunkc.z);
        mark_chunk_dirty(chunkc.x, chunkc.y+1, chunkc.z);
        mark_chunk_dirty(chunkc.x, chunkc.y-1, chunkc.z);
        mark_chunk_dirty(chunkc.x, chunkc.y, chunkc.z+1);
        mark_chunk_dirty(chunkc.x, chunkc.y, chunkc.z-1);
    }
    
    void mark_chunk_dirty(int x, int y, int z) {
        return mark_chunk_dirty(vec3i(x, y, z));
    }
    
    void mark_chunk_dirty(vec3i chunkc) {
        if(Chunk* c = chunkc in chunks) {
            c.dirty = true;
        }
    }
       
    // rendering

    // fills the vbo with the chunk content
    // original version from florian boesch - http://codeflow.org/
    size_t tessellate(Chunk chunk, vec3i chunkc, TessellationBuffer* tb) {
        Tessellator tessellator = Tessellator(this, atlas, engine.resmgr.get!Gloom("sphere"), tb);

        int index;
        int y;
        int hds = height / 16;

        float z_offset, z_offset_n;
        float y_offset, y_offset_t;
        float x_offset, x_offset_r;

        Block value;
        Block right_block;
        Block front_block;
        Block top_block;

        vec3i wcoords_orig = vec3i(chunkc.x*chunk.width, chunkc.y*chunk.height, chunkc.z*chunk.depth);
        vec3i wcoords = wcoords_orig;


        foreach(b; 0..hds) {
            if((chunk.primary_bitmask >> b) & 1 ^ 1) continue;
            foreach(y_; 0..hds) {
                y = b*hds + y_;

                y_offset = wcoords_orig.y + y + 0.5f;
                y_offset_t = y_offset + 1.0f;

                wcoords.y = wcoords_orig.y + y;
                wcoords.z = wcoords_orig.z;

                tessellator.trigger_realloc();

                foreach(z; 0..depth) {
                    z_offset = wcoords_orig.z + z + 0.5f;
                    z_offset_n = z_offset + 1.0f;

                    wcoords.x = wcoords_orig.x;
                    wcoords.z = wcoords_orig.z + z;

                    value = chunk.get_block_safe(0, y, z, AIR_BLOCK);

                    foreach(x; 0..width) {
                        x_offset = wcoords_orig.x + x + 0.5f;
                        x_offset_r = x_offset + 1.0f;
                        wcoords.x = wcoords_orig.x + x;

                        index = x+z*depth+y*ystep;

                        if(x == width-1) {
                            right_block = get_block_safe(wcoords.x+1, wcoords.y, wcoords.z, AIR_BLOCK);
                        } else {
                            right_block = chunk.blocks[index+1];
                        }

                        if(z == depth-1) {
                            front_block = get_block_safe(wcoords.x, wcoords.y, wcoords.z+1, AIR_BLOCK);
                        } else {
                            front_block = chunk.blocks[index+width];
                        }

                        if(y == height-1) {
                            top_block = AIR_BLOCK;
                        } else {
                            top_block = chunk.blocks[index+ystep];
                        }

                        tessellator.feed(chunk, wcoords, x, y, z,
                                        x_offset, x_offset_r, y_offset, y_offset_t, z_offset, z_offset_n,
                                        value, right_block, top_block, front_block,
                                        biome_set.biomes[chunk.get_biome_safe(x+z*15)]);

                        value = right_block;
                    }
                }
            }
        }

        chunk.vbo_vcount = tessellator.terrain_elements / Vertex.sizeof;

        debug {
            assert(cast(size_t)tb.terrain.ptr % 4 == 0, "whatever I did check here isn't true anylonger");
            //assert(tessellator.terrain_elements*Vertex.sizeof % 4 == 0, "");
            static assert(Vertex.sizeof % 4 == 0, "Vertex struct is not a multiple of 4");
        }

        return tessellator.terrain_elements;
    }

    void postprocess_chunks() {
        if(auto tess_out = tessellation_thread.get()) with(*tess_out) {
            scope(exit) buffer.available = true;

            if(chunk.empty) {
                logger.log!Debug("Chunk is empty, skipping!");
                return;
            }

            if(chunk.vbo is null) {
                chunk.vao = new VAO();
                chunk.vbo = new Buffer();
            }

            chunk.vao.bind();
            scope(success) chunk.vao.unbind();
            chunk.vbo.bind();
            scope(success) chunk.vbo.unbind();

            chunk.vbo.set_data(buffer.terrain.ptr, elements);

            assert(chunk.vbo !is null, "chunk vbo is null");
            assert(engine.current_shader !is null, "current shader is null");
            Vertex.bind(engine.current_shader, chunk.vbo);

            chunk.tessellated = true;
        }

        version(NoThreads)
        if(input.read_count != 0) {
            tessellation_thread.poll();
        }
    }

    void check_chunk(Chunk chunk, vec3i chunkc) {
        if(!chunk.empty && chunk.dirty && chunk.tessellated) {
            chunk.dirty = false;
            chunk.tessellated = false;
            input.write_one(ChunkData(chunk, chunkc));
        }
    }
}


final class TessellationThread : VerboseThread {
    protected TessellationBuffer buffer;
    protected World world;
    protected RingBuffer!ChunkData input;
    protected TessOut output;
    protected bool ready = false;
    protected bool _stop = false;

    this(World world, RingBuffer!ChunkData input) {
        super(&run);

        this.world = world;
        this.buffer = TessellationBuffer(world.default_tessellation_buffer_size,
                                         world.default_light_buffer_size);
        this.input = input;
    }
    
    void free() {
        logger.log!Info(`Freeing tessellation buffer: "%s"`, this.name);
        if(!_stop) {
            // this is an error, because we free data at the end!
            // Logically this should never happen, but if it happens
            // let's hope it's not critical.
            logger.log!Error_("Free called, but thread not stopped!");
            stop();
        }

        buffer.free();
    }

    void run() {
        while(!_stop) {
            poll();
        }
    }

    void stop() {
        logger.log!Info(`Setting stop for: "%s"`, this.name);
        _stop = true;
    }

    @property
    bool stopped() {
        return _stop;
    }
            
    void poll() {
        // waits only if the buffer is not available
        buffer.wait_available();
        if(_stop) return;

        ChunkData chunk_data;
        if(input.ringbuffer.read(&chunk_data, 1) == 0) {
            // we don't want the thread to be running all the time
            // take a break if there is nothing to do!
            Thread.sleep(350.msecs);
            return;
        }

        with(chunk_data) {
            if(chunk.empty) {
                logger.log!Debug("Chunk is empty, skipping! %s", position);
                return;
            } else if(chunk.tessellated) {
                logger.log!Debug("Chunk is already tessellated! %s", position);
                return;
            } else {
                buffer.available = false;
            }

            size_t elements = world.tessellate(chunk, position, &buffer);

            output = TessOut(chunk, &buffer, elements);
            ready = true;
        }       
    }

    TessOut* get() {
        if(ready) {
            ready = false;
            return &output;
        }
        return null;
    }
}
