import glob, os
from PIL import Image
for f in glob.glob('/tmp/shots/*.png'):
    im = Image.open(f).convert('RGB')
    im = im.resize((540, 1170), Image.LANCZOS)
    im.save('/home/claude/guide/img/' + os.path.basename(f)[:-4] + '.jpg', quality=86)
