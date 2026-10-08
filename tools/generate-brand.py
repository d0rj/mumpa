"""Build original Mumpa platform icons from simple waveform geometry."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
image = Image.new('RGB', (1024, 1024), '#142014')
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((16,16,1008,1008), radius=240, fill='#142014')
for x, height in zip([260,386,512,638,764], [230,460,670,350,160]):
    draw.rounded_rectangle((x-34,512-height//2,x+34,512+height//2),radius=34,fill='#D3F76B')
sizes={'mdpi':48,'hdpi':72,'xhdpi':96,'xxhdpi':144,'xxxhdpi':192}
for density, size in sizes.items():
    out=ROOT/'android/app/src/main/res'/f'mipmap-{density}'/'ic_launcher.png'
    out.parent.mkdir(parents=True,exist_ok=True)
    image.resize((size,size),Image.Resampling.LANCZOS).save(out)
image.save(ROOT/'windows/runner/resources/app_icon.ico',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
(ROOT/'assets/brand').mkdir(exist_ok=True)
image.resize((256,256),Image.Resampling.LANCZOS).save(ROOT/'assets/brand/mumpa.png')
print('Generated Mumpa platform icons')
