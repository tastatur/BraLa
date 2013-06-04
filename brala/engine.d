module brala.engine;

private {
    import glamour.gl;
    import glamour.shader : Shader;
    import glamour.texture : ITexture;
    import glamour.sampler : Sampler;
    
    import glwtf.glfw;
    import glwtf.window;
    
    import gl3n.linalg;
    import gl3n.frustum : Frustum;

    import brala.exception : ResmgrError;
    import brala.log : logger = engine_logger;
    import brala.utils.log;
    import brala.timer : Timer, TickDuration;
    import brala.resmgr : ResourceManager;
    import brala.utils.config : Config;
}

class BraLaEngine {
    protected vec2i _viewport = vec2i(0, 0);
    Timer timer;
    ResourceManager resmgr;
    Window window;
    Config config;

    @property vec2i viewport() {
        return _viewport;
    }
    
    mat4 model = mat4.identity;
    mat4 view = mat4.identity;
    mat4 proj = mat4.identity;
    
    @property mat4 mvp() {
        return proj * view * model;
    }
    
    @property mat4 mv() {
        return view * model;
    }

    @property Frustum frustum() {
        return Frustum(mvp);
    }
    
    protected Shader _current_shader = null;
    protected ITexture _current_texture = null;
    protected Sampler _current_sampler = null;
    Sampler[ITexture] samplers;
    
    @property Shader current_shader() { return _current_shader; }
    @property void current_shader(Shader shader) {
        if(_current_shader !is null) _current_shader.unbind();
        _current_shader = shader;
        _current_shader.bind();
    }

    @property ITexture current_texture() { return _current_texture; }
    @property void current_texture(ITexture texture)
        in { assert(texture !is null, "Current texture can not be set to null"); }
        body {
            _current_texture = texture;
            _current_texture.activate();
            _current_texture.bind();
            if(Sampler* sampler = _current_texture in samplers) {
                _current_sampler = *sampler;
                _current_sampler.bind(_current_texture);
            }
        }
    
    this(Window window, Config config) {
        this.window = window;
        this.config = config;
        
        timer = new Timer();
        resmgr = new ResourceManager();
        
        resize(window.width, window.height);
        window.on_resize.connect(&resize);

        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LEQUAL);
        glEnable(GL_CULL_FACE);

        // wireframe mode, for debugging
        //glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
    }

    void shutdown() {
        logger.log!Info("Removing Samplers from Engine");
        foreach(sampler; samplers.values) {
            sampler.remove();
        }
        
        resmgr.shutdown();
    }

    void resize(int width, int height) {
        _viewport = vec2i(width, height);
        glViewport(0, 0, width, height);
    }
    
    void mainloop(bool delegate(TickDuration) callback) {
        bool stop = false;
        timer.start();
        
        TickDuration now, last;
        debug TickDuration lastfps = TickDuration(0);
        
        while(true) {
            now = timer.get_time();
            TickDuration delta_ticks = (now - last);

            if(callback(delta_ticks)) {
                break;
            }
        
            debug {
                TickDuration t = timer.get_time();
                if((t-lastfps).to!("seconds", float) > 0.5) {
                    logger.log!Info("Frame-Time: %s ms", (t-last).to!("msecs", float));
                    lastfps = t;
                }
            }
            
            last = now;

            window.swap_buffers();
            glfwPollEvents();
        }
        
        TickDuration ts = timer.stop();
        logger.log!Info("Mainloop ran %f seconds", ts.to!("seconds", float));
    }
    
    void use_shader(Shader shader) {
        current_shader = shader;
    }
    
    void use_shader(string id) {
        current_shader = resmgr.get!Shader(id);
    }
    
    void flush_uniforms() {
        flush_uniforms(_current_shader, true);
    }
    
    void flush_uniforms(Shader shader, bool bound = false) {
        if(!bound) shader.bind();
        
        shader.uniform("viewport", viewport);
        shader.uniform("model", model);
        shader.uniform("view", view);
        shader.uniform("proj", proj);
    }

    void set_texture(string tex_id, ITexture texture, Sampler new_sampler = null)
        in { assert(texture !is null, "Can't set a null texture"); }
        body {
            ITexture old;
            try {
                old = resmgr.get!ITexture(tex_id);
                resmgr.remove!ITexture(tex_id);
            } catch(ResmgrError) {}

            Sampler tex_sampler = new_sampler;
            if(old !is null && tex_sampler is null) {
                if(Sampler* sampler = old in samplers) {
                    tex_sampler = *sampler;
                }
            }
            samplers.remove(old);

            resmgr.add(tex_id, texture);
            if(tex_sampler !is null) {
                set_sampler(texture, tex_sampler);
            }
        }

    void use_texture(ITexture texture)
        in { assert(texture !is null, "Tried to use null texture"); }
        body {
            current_texture = texture;
        }

    void use_texture(string id) {
        current_texture = resmgr.get!ITexture(id);
    }

    void set_sampler(ITexture tex, Sampler s)
        in { assert(s !is null, "Can't set a null sampler"); }
        body {
            samplers[tex] = s;
        }
    
    void set_sampler(string tex_id, Sampler s)
        in { assert(s !is null, "Can't set a null sampler"); }
        body {
            samplers[resmgr.get!ITexture(tex_id)] = s;
        }

    void use_sampler(string tex_id) {
        _current_sampler = samplers[resmgr.get!ITexture(tex_id)];
        _current_sampler.bind(_current_texture);
    }
}
