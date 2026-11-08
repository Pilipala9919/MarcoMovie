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
        return dict(name=NAME, resource=resource.strip(), request=reply)

    def detailContent(self, ids):
        from later import EPISODE
        return dict(episode=EPISODE)
