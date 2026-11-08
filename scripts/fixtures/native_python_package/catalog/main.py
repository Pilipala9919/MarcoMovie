import json
from importlib.resources import files
from base.spider import Spider as BaseSpider
from .helpers import label


class Spider(BaseSpider):
    def init(self, extension):
        self.origin = json.loads(extension)['origin']
        self.raw = extension
        self.calls = 0

    def homeContent(self, filtered):
        self.calls += 1
        response = self.fetch(self.origin + '/echo')
        return {'class': [{'type_id': 'film', 'type_name': label()}],
                'resource': json.loads(files('catalog').joinpath('data/catalog.json').read_text())['item'],
                'calls': self.calls, 'raw': self.raw, 'http': response.json()}

    def homeVideoContent(self):
        return {'list': [{'vod_id': 'one', 'vod_name': label()}]}

    def categoryContent(self, category, page, filtered, extend):
        return {'category': category, 'page': page, 'filter': extend, 'list': []}

    def searchContent(self, word, quick, page='1'):
        return {'list': [{'vod_id': word, 'vod_name': word}], 'page': page}

    def detailContent(self, ids):
        return {'list': [{'vod_id': ids[0], 'vod_play_from': 'owned', 'vod_play_url': '第一集$one'}]}

    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': self.getProxyUrl({'id': id})}

    def localProxy(self, params):
        self.calls += 1
        # Above the fixture bridge's former 1 MiB JSON limit; still comfortably
        # within the product's 6 MiB binary response contract.
        body = bytes(range(256)) * 5000
        return [206, 'application/octet-stream', body,
                {'X-Instance-Calls': str(self.calls), 'Content-Range': 'bytes 0-1279999/1280000'}]

    def liveContent(self, url):
        if url == 'slow':
            return self.fetch(self.origin + '/slow').json()
        return '#EXTM3U\n#EXTINF:-1,Owned\nrelative/live.m3u8\n'
