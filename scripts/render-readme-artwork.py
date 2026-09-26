"""Render the README's real UI layers with Blender 5.x (no third-party add-ons).

Run: blender --background --python scripts/render-readme-artwork.py -- --output docs/images
The screenshot is an isolated demonstration library, never a user's live library.
"""
import argparse
import math
from pathlib import Path
import sys
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=ROOT / 'docs/images')
parser.add_argument('--samples', type=int, default=64)
parser.add_argument('--width', type=int, default=1800)
parser.add_argument('--only', choices=['mac', 'inline', 'consent', 'all'], default='all')
parser.add_argument('--save-blend', action='store_true', help='Also export portable Blender scenes')
options = parser.parse_args(args)
options.output.mkdir(parents=True, exist_ok=True)


def material(name, color, roughness=.5):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value = (*color, 1)
    shader.inputs['Roughness'].default_value = roughness
    return mat


def setup():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = options.samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x = options.width
    scene.render.resolution_y = round(options.width * 1.02)
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.view_settings.view_transform = 'Standard'
    scene.view_settings.look = 'None'
    # A neutral studio environment opens the shadows; broad softboxes give the
    # graphite edges shape without putting hot highlights over interface text.
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes.get('Background')
    background.inputs['Color'].default_value = (.97, .98, 1, 1)
    background.inputs['Strength'].default_value = .65
    # Let the README's dark page show through rather than baking in a white card.
    scene.render.film_transparent = True
    floor = material('Shadow catcher', (.5, .5, .5), 1)
    floor_shader = floor.node_tree.nodes.get('Principled BSDF')
    floor_shader.inputs['Specular IOR Level'].default_value = .08
    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, -1.0))
    bpy.context.object.data.materials.append(floor)
    bpy.context.object.is_shadow_catcher = True
    for name, loc, power, size in [
            ('Key softbox', (-5, 2, 10), 1000, 8),
            ('Edge softbox', (6, 3, 7), 700, 6),
            ('Front fill', (1, -6, 10), 450, 10)]:
        data = bpy.data.lights.new(name, 'AREA')
        data.energy = power
        data.shape = 'DISK'
        data.size = size
        obj = bpy.data.objects.new(name, data)
        scene.collection.objects.link(obj)
        obj.location = loc
        obj.rotation_euler = (-obj.location).to_track_quat('-Z', 'Y').to_euler()
    data = bpy.data.cameras.new('Art direction')
    camera = bpy.data.objects.new('Art direction', data)
    scene.collection.objects.link(camera)
    camera.location = (8, -12, 21)
    camera.rotation_euler = (-camera.location).to_track_quat('-Z', 'Y').to_euler()
    data.type = 'ORTHO'
    data.ortho_scale = 12.8
    scene.camera = camera
    return scene, camera


def rounded_surface(name, width, height, radius, z, texture=None, uv=(0, 0, 1, 1), mat=None, center=(0, 0)):
    outline = []
    for cx, cy, angle in [(width/2-radius, height/2-radius, 0), (-width/2+radius, height/2-radius, 90), (-width/2+radius, -height/2+radius, 180), (width/2-radius, -height/2+radius, 270)]:
        for step in range(17):
            theta = math.radians(angle + step * 90/16)
            outline.append((cx + radius * math.cos(theta), cy + radius * math.sin(theta), 0))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(0,0,0)] + outline, [], [(0, i+1, (i+1) % len(outline)+1) for i in range(len(outline))])
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.location = (*center, z)
    if texture:
        mat = bpy.data.materials.new(name + ' actual screenshot')
        mat.use_nodes = True
        nodes = mat.node_tree.nodes
        shader = nodes.get('Principled BSDF')
        tex = nodes.new('ShaderNodeTexImage')
        tex.image = texture
        tex.interpolation = 'Linear'
        color_output = tex.outputs['Color']
        if name == 'Native Mac workspace':
            # Retouch only the captured pointer in empty chrome, in the texture
            # itself: an extra geometry patch would cast an unwanted tiny shadow.
            links = mat.node_tree.links
            coordinates = nodes.new('ShaderNodeTexCoord')
            separate = nodes.new('ShaderNodeSeparateXYZ')
            links.new(coordinates.outputs['UV'], separate.inputs[0])
            shift = nodes.new('ShaderNodeVectorMath')
            shift.operation = 'ADD'
            shift.inputs[1].default_value = (-30 / texture.size[0], 0, 0)
            links.new(coordinates.outputs['UV'], shift.inputs[0])
            clean = nodes.new('ShaderNodeTexImage')
            clean.image = texture
            links.new(shift.outputs[0], clean.inputs['Vector'])
            masks = []
            for axis, operation, threshold in [('X','GREATER_THAN',716/868),
                    ('X','LESS_THAN',744/868),('Y','GREATER_THAN',624/667),
                    ('Y','LESS_THAN',654/667)]:
                test = nodes.new('ShaderNodeMath')
                test.operation = operation
                links.new(separate.outputs[axis], test.inputs[0])
                test.inputs[1].default_value = threshold
                masks.append(test.outputs[0])
            mask = masks[0]
            for other in masks[1:]:
                multiply = nodes.new('ShaderNodeMath')
                multiply.operation = 'MULTIPLY'
                links.new(mask, multiply.inputs[0])
                links.new(other, multiply.inputs[1])
                mask = multiply.outputs[0]
            mix = nodes.new('ShaderNodeMixRGB')
            links.new(mask, mix.inputs[0])
            links.new(tex.outputs['Color'], mix.inputs[1])
            links.new(clean.outputs['Color'], mix.inputs[2])
            color_output = mix.outputs[0]
        mat.node_tree.links.new(color_output, shader.inputs['Base Color'])
        mat.node_tree.links.new(color_output, shader.inputs['Emission Color'])
        shader.inputs['Emission Strength'].default_value = .28
        shader.inputs['Roughness'].default_value = .84
        shader.inputs['Specular IOR Level'].default_value = .04
        uv_layer = mesh.uv_layers.new()
        u0, v0, u1, v1 = uv
        for face in mesh.polygons:
            for loop_idx in face.loop_indices:
                point = mesh.vertices[mesh.loops[loop_idx].vertex_index].co
                uv_layer.data[loop_idx].uv = (u0+(point.x/width+.5)*(u1-u0), v0+(point.y/height+.5)*(v1-v0))
    obj.data.materials.append(mat)
    return obj


def body(name, width, height, center, z, radius=.12, thickness=.06):
    mat = material(name + ' graphite edge', (.065,.067,.075), .28)
    mat.node_tree.nodes.get('Principled BSDF').inputs['Metallic'].default_value = .3
    obj = rounded_surface(name, width, height, radius, z, mat=mat, center=center)
    solid = obj.modifiers.new('Physical thickness', 'SOLIDIFY')
    solid.thickness = thickness
    solid.offset = -1
    bevel = obj.modifiers.new('Light-catching edge', 'BEVEL')
    bevel.width = .015
    bevel.segments = 3
    return obj


def screen_layer(image, name, crop, z, thickness=.06):
    sw, sh = image.size
    x0, y0, x1, y1 = crop
    width, height = (x1-x0)/100, (y1-y0)/100
    center = ((x0+x1-sw)/200, (sh-y0-y1)/200)
    radius = min(.13, width/4, height/4)
    body(name + ' backing', width, height, center, z, radius, thickness)
    return rounded_surface(name, width, height, radius, z+.006, texture=image,
        uv=(x0/sw,1-y1/sh,x1/sw,1-y0/sh),center=center)


def label(camera, body, x, y, size, color, weight='Semibold'):
    curve = bpy.data.curves.new(body, type='FONT')
    curve.body = body
    curve.size = size
    curve.space_line = .76
    font_path = Path('/Library/Fonts') / f'SF-Pro-Display-{weight}.otf'
    if font_path.exists(): curve.font = bpy.data.fonts.load(str(font_path), check_existing=True)
    obj = bpy.data.objects.new(body, curve)
    bpy.context.collection.objects.link(obj)
    obj.parent = camera
    obj.location = (x, y, -8)
    mat = bpy.data.materials.new('Type ' + body)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    emission = nodes.new('ShaderNodeEmission')
    emission.inputs['Color'].default_value = (*color,1)
    out = nodes.new('ShaderNodeOutputMaterial')
    mat.node_tree.links.new(emission.outputs[0], out.inputs['Surface'])
    obj.data.materials.append(mat)
    return obj


def render_mac():
    scene, camera = setup()
    image = bpy.data.images.load(str(ROOT/'docs/images/macos-library.jpg'), check_existing=True)
    screen_layer(image, 'Native Mac workspace', (0,0,*image.size), .1)
    cuts = [('Selected entry',(17,320,251,382),.47), ('Your saved information',(292,96,844,415),.86), ('Keyword',(292,451,844,484),.43), ('Tags',(292,587,844,619),.34)]
    neutral = material('Recess under lifted views',(.025,.026,.029),.75)
    for name, crop, z in cuts:
        x0,y0,x1,y1=crop
        rounded_surface(name+' recess',(x1-x0)/100,(y1-y0)/100,.10,.115,mat=neutral,center=((x0+x1-image.size[0])/200,(image.size[1]-y0-y1)/200))
        screen_layer(image,name,crop,z)
    # Move the complete interface lower in the camera frame, leaving the headline clear.
    offset = camera.rotation_euler.to_quaternion() @ Vector((.25,-1.3,0))
    for obj in list(scene.objects):
        if obj.type=='MESH' and obj.name!='Plane': obj.location += offset
    label(camera,'Your library.\nWithin reach.',-5.65,4.75,1.08,(.87,.92,.97))
    label(camera,'LINKS  /  PASSWORDS  /  NOTES  /  API TOKENS',-5.60,2.84,.25,(.38,.43,.51),'Medium')
    label(camera,'NATIVE macOS',-5.60,-5.65,.26,(.48,.54,.63),'Semibold')
    label(camera,'Actual interface · layers separated for illustration',-5.60,-6.03,.23,(.28,.34,.43),'Regular')
    scene.render.filepath=str(options.output/'macos-layers.png')
    if options.save_blend:
        bpy.ops.file.pack_all()
        bpy.ops.wm.save_as_mainfile(filepath=str(options.output/'macos-layers.blend'))
    bpy.ops.render.render(write_still=True)

def render_front():
    scene,camera=setup()
    camera.location=(0,0,21)
    camera.rotation_euler=(0,0,0)
    image=bpy.data.images.load(str(ROOT/'docs/images/macos-library.jpg'),check_existing=True)
    screen_layer(image,'Native Mac workspace',(0,0,*image.size),.1)
    for obj in list(scene.objects):
        if obj.type=='MESH' and obj.name!='Plane': obj.location.y-=.65
    label(camera,'A place for everything\nyou keep looking up.',-5.65,4.75,1.08,(.87,.92,.97))
    label(camera,'SEARCH  /  TAGS  /  PINS  /  YOUR OWN KEYWORDS',-5.60,2.84,.25,(.38,.43,.51),'Medium')
    label(camera,'SNIPPETS FOR MAC',-5.60,-5.65,.26,(.48,.54,.63))
    label(camera,'One library for your everyday information.',-5.60,-6.03,.23,(.28,.34,.43),'Regular')
    scene.render.filepath=str(options.output/'macos-overview.png')
    bpy.ops.render.render(write_still=True)

def render_inline():
    # A flat before/after composition: the interaction must read at README size.
    # Keep the production suggestion view as a texture; typeset only the fictional
    # surrounding message and the explanatory captions. No extrusion or lighting.
    scene, camera = setup()
    for obj in list(scene.objects):
        if obj != camera:
            bpy.data.objects.remove(obj, do_unlink=True)
    scene.render.resolution_y = round(options.width * .60)
    camera.location = (0, 0, 20)
    camera.rotation_euler = (0, 0, 0)
    camera.data.ortho_scale = 18

    def color(hex_value):
        channels = [int(hex_value[i:i+2], 16) / 255 for i in (1, 3, 5)]
        return tuple(v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4
                     for v in channels)

    def flat_material(name, hex_value):
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        nodes = mat.node_tree.nodes
        nodes.clear()
        emission = nodes.new('ShaderNodeEmission')
        emission.inputs['Color'].default_value = (*color(hex_value), 1)
        output = nodes.new('ShaderNodeOutputMaterial')
        mat.node_tree.links.new(emission.outputs[0], output.inputs['Surface'])
        return mat

    field = flat_material('Illustrative message field', '#171e29')
    for x in (-4.15, 4.15):
        rounded_surface('Message', 7.9, 5.5, .24, 0, mat=field, center=(x, -.75))

    ink, muted = color('#f0f6fc'), color('#9ba8b9')
    text, accent = color('#eef0f6'), color('#b4adff')
    label(camera, 'Your saved links. Right where you type.', -8.10, 4.15, 1.14, ink)
    label(camera, 'Find a suggestion. Press Return. Keep typing.', -8.08, 3.40, .54, muted, 'Regular')
    label(camera, '01   TYPE & CHOOSE', -8.08, 2.45, .46, ink)
    label(camera, '02   INSERT & CONTINUE', .22, 2.45, .46, ink)

    for x in (-7.65, .65):
        label(camera, 'Hi team,', x, 1.23, .58, text, 'Regular')
        label(camera, 'Here is the link for our next review:', x, .47, .58, text, 'Regular')
    label(camera, '\\me', -7.65, -.29, .62, accent, 'Medium')
    rounded_surface('Insertion caret', .025, .35, 0, .1,
                    mat=flat_material('Caret', '#b4adff'),
                    center=(-7.14, -.11))

    # The native 320 × 108 pt view is exported at 4×, then reduced in the scene.
    # Cropping the old 1× window capture here visibly blurred its small labels.
    image = bpy.data.images.load(str(ROOT/'docs/images/inline-suggestions.png'), check_existing=True)
    suggestion = rounded_surface('Native suggestion view', 5.76, 1.944, .36, .1,
        texture=image, center=(-4.77, -1.50))
    # Preserve the captured view's colors exactly, without material highlights.
    mat = suggestion.data.materials[0]
    nodes = mat.node_tree.nodes
    texture = next(node for node in nodes if node.type == 'TEX_IMAGE')
    output = nodes.get('Material Output')
    emission = nodes.new('ShaderNodeEmission')
    mat.node_tree.links.new(texture.outputs['Color'], emission.inputs['Color'])
    mat.node_tree.links.new(emission.outputs[0], output.inputs['Surface'])

    label(camera, 'https://meet.example.com/design-review', .65, -.29, .58, text, 'Regular')
    label(camera, 'The saved link replaces your keyword.', .65, -2.76, .46, color('#aeb6c7'), 'Regular')
    label(camera, 'macOS INLINE INSERTION', -8.08, -4.23, .38, ink)
    label(camera, 'Native suggestion view · Illustrative message with fictional content', -8.08, -4.78, .37, muted, 'Regular')
    scene.render.filepath = str(options.output/'inline-insertion.png')
    bpy.ops.render.render(write_still=True)


def render_consent():
    # AppKit's 4× layer export keeps the native text crisp but omits the system
    # glass button surfaces. Restore those two regions from the native window
    # capture, preserving their production positions, labels, and appearance.
    scene, camera = setup()
    for obj in list(scene.objects):
        if obj != camera:
            bpy.data.objects.remove(obj, do_unlink=True)
    scene.render.resolution_y = round(options.width * 2 / 3)
    scene.cycles.use_denoising = False
    camera.location = (0, 0, 20)
    camera.rotation_euler = (0, 0, 0)
    camera.data.ortho_scale = 19.2

    def flat(name, channels):
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        nodes = mat.node_tree.nodes
        nodes.clear()
        emission = nodes.new('ShaderNodeEmission')
        linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4
                  for v in channels]
        emission.inputs['Color'].default_value = (*linear, 1)
        output = nodes.new('ShaderNodeOutputMaterial')
        mat.node_tree.links.new(emission.outputs[0], output.inputs['Surface'])
        return mat

    def unlit_texture(obj, backing=None):
        mat = obj.data.materials[0]
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        texture = next(node for node in nodes if node.type == 'TEX_IMAGE')
        emission = nodes.new('ShaderNodeEmission')
        color = texture.outputs['Color']
        if backing:
            # Composite native alpha directly in the shader so flat backgrounds
            # stay noise-free; transparent rays would add Monte Carlo grain.
            mix = nodes.new('ShaderNodeMixRGB')
            links.new(texture.outputs['Alpha'], mix.inputs[0])
            mix.inputs[1].default_value = (*backing, 1)
            links.new(color, mix.inputs[2])
            color = mix.outputs[0]
        links.new(color, emission.inputs['Color'])
        links.new(emission.outputs[0], nodes.get('Material Output').inputs['Surface'])

    # A neutral dark frame replaces the screen-dependent glass backdrop. The
    # 22 pt corner radius and 1 pt border follow the production consent window.
    border = flat('Consent border', (88/255, 94/255, 102/255))
    backing = flat('Consent dark backing', (43/255, 46/255, 50/255))
    rounded_surface('Consent frame', 19.2, 12.8, .88, 0, mat=border)
    content = bpy.data.images.load(str(ROOT/'docs/artwork/sources/consent-content.png'), check_existing=True)
    native = rounded_surface('Native consent content', 19.12, 12.72, .84, .002,
        texture=content, uv=(4/1920, 4/1280, 1916/1920, 1276/1280))
    backing_color = next(node for node in backing.node_tree.nodes
                         if node.type == 'EMISSION').inputs['Color'].default_value[:3]
    unlit_texture(native, backing=backing_color)

    controls = bpy.data.images.load(str(ROOT/'docs/artwork/sources/consent-controls.jpg'), check_existing=True)
    sw, sh = controls.size
    for name, crop in [('Deny', (520, 566, 712, 630)), ('Reveal', (728, 566, 948, 630))]:
        x0, y0, x1, y1 = crop
        # The source has a 36 px window-shadow inset and is captured at 2×.
        width, height = (x1-x0)/50, (y1-y0)/50
        center = ((x0+x1-1032)/100, (712-y0-y1)/100)
        button = rounded_surface('Native '+name+' button', width, height, .24, .003,
            texture=controls, uv=(x0/sw, 1-y1/sh, x1/sw, 1-y0/sh), center=center)
        unlit_texture(button)

    scene.render.filepath = str(options.output/'cli-secure-consent.png')
    bpy.ops.render.render(write_still=True)


if options.only in ('mac','all'):
    render_mac()
    render_front()
if options.only in ('inline','all'):
    render_inline()
if options.only in ('consent','all'):
    render_consent()
