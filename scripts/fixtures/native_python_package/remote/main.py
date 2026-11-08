from base.spider import Spider as Base
from helpers import NAME
import importlib.resources
import json
import requests


class Spider(Base):
    def init(self, ext):
        self.origin = json.loads(ext)['origin']

    def homeContent(self, filter):
        resource = importlib.resources.files('helpers').joinpath('payload.txt').read_text(encoding='utf-8')
        reply = requests.get(self.origin + '/source-echo?q=with space').json()
        compressed = requests.get(self.origin + '/encoding', headers={
            'Accept-Encoding': 'gzip, deflate, br, zstd'}).json()
        preferred = requests.get(self.origin + '/encoding', headers={
            'Accept-Encoding': 'gzip;q=0, br, deflate;q=0.4, identity;q=0'}).json()
        return dict(name=NAME, resource=resource.strip(), request=reply,
                    compressed=compressed, preferred=preferred)

    def detailContent(self, ids):
        from later import EPISODE
        return dict(episode=EPISODE)
