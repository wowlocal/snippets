/* Same-client virtual keyboard passthrough is supported by Hyprland's
 * shouldIgnoreVirtualKeyboard. No callback retains a Rust check/context. */
static int popup_public(struct snip_ime *owner) {
    return !owner->failed && !owner->dirty && owner->current.active
        && owner->current.has_text && public_type(&owner->current);
}
static void popup_queue(struct snip_ime *owner, struct snip_ime_key event) {
    struct snip_popup *popup = &owner->popup;
    if (!popup_public(owner) || !popup->visible) { popup->keys_count=0; return; }
    if (popup->keys_count == 32) {
        owner->failed = 1; return;
    }
    event.field = owner->current.field; event.serial = owner->current.serial;
    if (popup->field!=event.field || popup->serial!=event.serial) event.modifiers|=256; /* old presentation */
    event.map_generation = popup->map_generation;
    popup->keys[popup->keys_count++] = event;
}
static void popup_xkb_log(struct xkb_context *context, enum xkb_log_level level, const char *format, va_list arguments) {
    (void)context; (void)level; (void)format; (void)arguments;
}
static void popup_map(void *data, struct zwp_input_method_keyboard_grab_v2 *grab,
                      uint32_t format, int32_t fd, uint32_t size) {
    (void)grab;
    struct snip_ime *owner = data; struct snip_popup *popup = &owner->popup;
    if (!popup->visible) { close(fd); return; }
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 || size < 2 || size > 1024 * 1024 || popup->map_generation == UINT32_MAX) {
        close(fd); owner->failed = 1; return;
    }
    struct stat info;
    if (fcntl(fd,F_SETFD,FD_CLOEXEC) || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < (off_t)size) { close(fd); owner->failed = 1; return; }
    char *text = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (text == MAP_FAILED) { close(fd); owner->failed = 1; return; }
    if (text[size-1] || strnlen(text, size) != size - 1) { munmap(text,size); close(fd); owner->failed = 1; return; }
    if (!popup->xkb) {
        popup->xkb = xkb_context_new(XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
        if (popup->xkb) xkb_context_set_log_fn(popup->xkb,popup_xkb_log);
    }
    struct xkb_keymap *map = popup->xkb ? xkb_keymap_new_from_string(popup->xkb, text, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
    munmap(text, size);
    struct xkb_state *state = map ? xkb_state_new(map) : NULL;
    if (!map || !state) { if (map) xkb_keymap_unref(map); close(fd); owner->failed = 1; return; }
    if (popup->state) xkb_state_unref(popup->state);
    if (popup->map) xkb_keymap_unref(popup->map);
    if (popup->map_fd >= 0) close(popup->map_fd);
    popup->state = state; popup->map = map; popup->map_fd = fd; popup->map_size = size;
    popup->map_generation++;
    /* Keep an early repeat_info; never silently discard physical input. */
    for (unsigned i=0;i<popup->keys_count;i++) {
        if (popup->keys[i].kind!=2) { owner->failed=1; return; }
        popup->keys[i].map_generation=popup->map_generation;
    }
}
static uint32_t popup_modifiers(struct snip_popup *popup) {
    const char *names[] = { XKB_MOD_NAME_SHIFT, XKB_MOD_NAME_CTRL, XKB_MOD_NAME_ALT, XKB_MOD_NAME_LOGO };
    uint32_t bits = 0;
    for (unsigned i = 0; i < 4; i++) if (xkb_state_mod_name_is_active(popup->state, names[i], XKB_STATE_MODS_EFFECTIVE) > 0) bits |= 1U << i;
    for (xkb_mod_index_t i=0;i<xkb_keymap_num_mods(popup->map);i++) {
        const char *name=xkb_keymap_mod_get_name(popup->map,i);
        if (xkb_state_mod_index_is_active(popup->state,i,XKB_STATE_MODS_EFFECTIVE)<=0) continue;
        if (!strcmp(name,XKB_MOD_NAME_CAPS)||!strcmp(name,XKB_MOD_NAME_NUM)) continue;
        unsigned known=0;
        for(unsigned n=0;n<4;n++)if(!strcmp(name,names[n]))known=1;
        /* Virtual aliases such as Alt/Meta/Super are already represented. */
        if(!known && i<8)bits|=16;
    }
    return bits;
}
static void popup_key(void *data, struct zwp_input_method_keyboard_grab_v2 *grab,
                      uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)grab; (void)serial;
    struct snip_ime *owner = data; struct snip_popup *popup = &owner->popup;
    if (!popup->visible) return;
    if (!popup->state || key > 767 || state > 1) { owner->failed = 1; return; }
    struct snip_ime_key event = { .key=key, .state=state, .time=time,
        .symbol=xkb_state_key_get_one_sym(popup->state, key+8), .modifiers=popup_modifiers(popup),
        .depressed=popup->depressed, .latched=popup->latched, .locked=popup->locked, .group=popup->group };
    popup_queue(owner, event);
}
static void popup_mods(void *data, struct zwp_input_method_keyboard_grab_v2 *grab, uint32_t serial,
                       uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
    (void)grab; (void)serial;
    struct snip_ime *owner = data; struct snip_popup *popup = &owner->popup;
    if (!popup->visible) return;
    if (!popup->state) { owner->failed = 1; return; }
    popup->depressed=depressed; popup->latched=latched; popup->locked=locked; popup->group=group;
    xkb_state_update_mask(popup->state, depressed,latched,locked,0,0,group);
    popup_queue(owner, (struct snip_ime_key){ .kind=1, .depressed=depressed, .latched=latched, .locked=locked, .group=group });
}
static void popup_repeat(void *data, struct zwp_input_method_keyboard_grab_v2 *grab, int32_t rate, int32_t delay) {
    (void)grab;
    struct snip_ime *owner = data;
    if (!owner->popup.visible) return;
    if (rate < 0 || rate > 200 || delay < 0 || delay > 10000) { owner->failed = 1; return; }
    popup_queue(owner, (struct snip_ime_key){ .kind=2, .symbol=(uint32_t)rate, .time=(uint32_t)delay });
}
static const struct zwp_input_method_keyboard_grab_v2_listener popup_grab_listener = {
    .keymap=popup_map, .key=popup_key, .modifiers=popup_mods, .repeat_info=popup_repeat
};
int snip_ime_popup(struct snip_ime *owner, uint64_t field, uint32_t serial,
                   const struct snip_popup_row *rows, uint32_t count, uint32_t selected,
                   const uint32_t *colors, snip_ime_check check, void *context) {
    if (!allowed(owner,check,context)) return 2;
    int64_t stamp=now_ms(); int status=pump(owner,stamp,check,context);
    if (status != 0 && status != 1) return status;
    if (!popup_public(owner) || field != owner->current.field || serial != owner->current.serial) return 2;
    if (!owner->compositor || !owner->shm || !owner->virtual_manager || !count || count>8 || selected>=count) return 3;
    struct snip_popup *popup=&owner->popup;
    popup_collect(popup,0);
    unsigned allocated=0; for (struct snip_popup_buffer *b=popup->buffers;b;b=b->next) allocated++;
    if (allocated >= 4) return 4; /* bounded backpressure, no stale row acceptance */
    int height=(int)count*SNIP_POPUP_ROW+36;
    size_t bytes=(size_t)height*SNIP_POPUP_WIDTH*4;
    int fd=memfd_create("snippets-public-popup",MFD_CLOEXEC|MFD_ALLOW_SEALING);
    if (fd<0 || ftruncate(fd,(off_t)bytes)) { if(fd>=0)close(fd); return 3; }
    void *pixels=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(pixels==MAP_FAILED){close(fd);return 3;}
    if(!snip_popup_render(pixels,bytes,rows,count,selected,colors)){munmap(pixels,bytes);close(fd);return 3;}
    struct wl_shm_pool *pool=wl_shm_create_pool(owner->shm,fd,(int32_t)bytes); close(fd);
    if(!pool){munmap(pixels,bytes);return 3;}
    struct snip_popup_buffer *buffer=calloc(1,sizeof(*buffer));
    if(!buffer){wl_shm_pool_destroy(pool);munmap(pixels,bytes);return 3;}
    buffer->buffer=wl_shm_pool_create_buffer(pool,0,SNIP_POPUP_WIDTH,height,SNIP_POPUP_WIDTH*4,WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    if(!buffer->buffer){free(buffer);munmap(pixels,bytes);return 3;}
    buffer->pixels=pixels;buffer->bytes=bytes;buffer->next=popup->buffers;popup->buffers=buffer;
    wl_buffer_add_listener(buffer->buffer,&popup_buffer_listener,buffer);
    if(!popup->surface){
        popup->surface=wl_compositor_create_surface(owner->compositor);
        if(!popup->surface)return 3;
        popup->role=zwp_input_method_v2_get_input_popup_surface(owner->method,popup->surface);
        if(!popup->role)return 3;
        zwp_input_popup_surface_v2_add_listener(popup->role,&popup_listener,owner);
        struct wl_region *region=wl_compositor_create_region(owner->compositor);
        if(!region)return 3;
        wl_surface_set_input_region(popup->surface,region);wl_region_destroy(region);
    }
    if(!popup->keyboard){
        popup->keyboard=zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(owner->virtual_manager,owner->seat);
        if(!popup->keyboard)return 3;
    }
    popup->field=field;popup->serial=serial;popup->visible=1;
    wl_surface_attach(popup->surface,buffer->buffer,0,0);
    wl_surface_damage(popup->surface,0,0,SNIP_POPUP_WIDTH,height);wl_surface_commit(popup->surface);
    if(!popup->grab){
        popup->grab=zwp_input_method_v2_grab_keyboard(owner->method);
        if(!popup->grab)return 3;
        zwp_input_method_keyboard_grab_v2_add_listener(popup->grab,&popup_grab_listener,owner);
    }
    return synchronize(owner,check,context);
}
int snip_ime_popup_hide(struct snip_ime *owner,snip_ime_check check,void *context){
    if(!allowed(owner,check,context))return 2;
    struct snip_popup *p=&owner->popup;p->visible=0;
    if(p->grab){zwp_input_method_keyboard_grab_v2_release(p->grab);p->grab=NULL;}
    if(p->keyboard){zwp_virtual_keyboard_v1_destroy(p->keyboard);p->keyboard=NULL;}
    if(p->surface){wl_surface_attach(p->surface,NULL,0,0);wl_surface_commit(p->surface);}
    if(p->state){xkb_state_unref(p->state);p->state=NULL;}
    if(p->map){xkb_keymap_unref(p->map);p->map=NULL;}
    if(p->map_fd>=0){close(p->map_fd);p->map_fd=-1;}
    p->keys_count=0;p->forwarded_map=0;
    return synchronize(owner,check,context);
}
int snip_ime_key_next(struct snip_ime *owner,struct snip_ime_key *event){
    struct snip_popup *p=&owner->popup;
    if(owner->failed||!p->keys_count)return 0;
    *event=p->keys[0];memmove(p->keys,p->keys+1,(--p->keys_count)*sizeof(*event));return 1;
}
int snip_ime_key_route(struct snip_ime *owner,const struct snip_ime_key *event,uint32_t consume,
                      snip_ime_check check,void *context){
    if(!allowed(owner,check,context))return 2;
    struct snip_popup *p=&owner->popup;
    if(!popup_public(owner)||!p->visible||!p->keyboard||!p->state
        ||event->field!=owner->current.field||event->serial!=owner->current.serial
        ||event->map_generation!=p->map_generation||event->kind>2||consume>1)return 2;
    if(consume||event->kind==2)return 0;
    owner->expected_field=event->field;owner->expected_serial=event->serial;owner->payload=1;
    if(p->forwarded_map!=p->map_generation){
        zwp_virtual_keyboard_v1_keymap(p->keyboard,WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,p->map_fd,p->map_size);
        p->forwarded_map=p->map_generation;
    }
    zwp_virtual_keyboard_v1_modifiers(p->keyboard,event->depressed,event->latched,event->locked,event->group);
    if(event->kind==0)zwp_virtual_keyboard_v1_key(p->keyboard,event->time,event->key,event->state);
    return synchronize(owner,check,context);
}
