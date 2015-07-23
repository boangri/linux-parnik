CREATE TABLE `parnik` (
  `ts` int(11) NOT NULL ,
  temp1 float default NULL,
  temp2 float default NULL,
  temp3 float default NULL,
  temp_fans float default NULL,
  temp_pump float default NULL,
  volt float default NULL,
  vol float default NULL,
  dist float default NULL,
  fans tinyint(4) default NULL,
  pump tinyint(4) default NULL,
  `sent` tinyint(4) default 0,
  PRIMARY KEY  (`ts`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 
