"""Upstream native API checks; no replacement XML parser or remote source URLs."""
from io import BytesIO
from lxml import etree, html, objectify


class OwnerElement(etree.ElementBase):
    pass


def exercise(owner, rounds):
    checks = 0
    namespace = etree.FunctionNamespace('urn:marco:lxml-owner')
    namespace['identity'] = lambda context: owner
    parser = etree.XMLParser()
    parser.set_element_class_lookup(etree.ElementDefaultClassLookup(element=OwnerElement))
    etree.set_default_parser(parser)
    for _ in range(rounds):
        root = etree.fromstring('<catalog><item year="2026">电影</item><item>二</item></catalog>')
        assert isinstance(root, OwnerElement)
        assert root.xpath('string(item[@year="2026"])') == '电影'
        assert root.xpath('count(item)') == 2.0
        assert root.xpath('owner:identity()', namespaces={'owner': 'urn:marco:lxml-owner'}) == owner
        assert etree.tostring(root, encoding='unicode').startswith('<catalog>')
        checks += 5
        document = html.fromstring('<html><body><a href="/video">播放</a></body></html>')
        assert document.xpath('//a/@href') == ['/video']
        assert document.text_content() == '播放'
        checks += 2
        data = objectify.fromstring(b'<root><number>42</number><flag>true</flag></root>')
        assert data.number.pyval == 42 and data.flag.pyval is True
        checks += 1
        events = list(etree.iterparse(BytesIO(b'<root><item>one</item><item>two</item></root>'), tag='item'))
        assert [element.text for _, element in events] == ['one', 'two']
        checks += 1
        try:
            etree.fromstring('<broken>')
            raise AssertionError('invalid XML was accepted')
        except etree.XMLSyntaxError as error:
            assert error.error_log.last_error is not None
        assert etree.fromstring('<after-error/>').tag == 'after-error'
        checks += 2
        stylesheet = etree.XML(b'<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><out><xsl:value-of select="/catalog/item[1]"/></out></xsl:template></xsl:stylesheet>')
        transformed = etree.XSLT(stylesheet)(root)
        assert transformed.getroot().text == '电影'
        checks += 1
        class Resolver(etree.Resolver):
            def resolve(self, url, public_id, context):
                return self.resolve_string('<!ENTITY owner "' + owner + '">', context)
        resolving = etree.XMLParser(load_dtd=True, resolve_entities=True)
        resolving.resolvers.add(Resolver())
        resolved = etree.fromstring(b'<!DOCTYPE root SYSTEM "owner.dtd"><root>&owner;</root>', resolving)
        assert resolved.text == owner
        checks += 1
    return checks
