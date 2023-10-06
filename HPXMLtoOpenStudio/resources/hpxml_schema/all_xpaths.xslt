<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">

    <xsl:output method="text" indent="no" />

    <xsl:template match="*[not(*)]">
        <xsl:for-each select="ancestor-or-self::*">
            <xsl:value-of select="concat('/', name())"/>
        </xsl:for-each>
        <xsl:text>&#xA;</xsl:text>
        <xsl:apply-templates select="*"/>
    </xsl:template>

    <xsl:template match="*">
        <xsl:apply-templates select="*"/>
    </xsl:template>

</xsl:stylesheet>
